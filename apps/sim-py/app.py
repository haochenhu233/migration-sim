#!/usr/bin/env python3
"""sim-py -- the Redis->Valkey migration probe app. Implements CHECK-CONTRACT.md.
One codebase, parameterized by env: SIM_MODE (cache|session|store|producer|consumer|lock),
SIM_SOURCE (vcap|env|ups), SIM_AUTH (password|username). See ../../CHECK-CONTRACT.md.
"""
import hashlib, json, os, socket, statistics, threading, time, uuid
from collections import deque
from datetime import datetime, timezone

import redis
from flask import Flask, jsonify

# ----------------------------------------------------------------------------- config
MODE     = os.environ.get("SIM_MODE", "cache")
SOURCE   = os.environ.get("SIM_SOURCE", "vcap")
SVC_NAME = os.environ.get("SIM_SERVICE_NAME", "")
AUTH     = os.environ.get("SIM_AUTH", "username")
EXPECTS  = os.environ.get("SIM_EXPECTS", "")
SEED     = int(os.environ.get("SIM_SEED", "1"))
NKEYS    = int(os.environ.get("SIM_KEYS", "1000" if MODE == "store" else "200"))
INTERVAL = int(os.environ.get("SIM_INTERVAL_MS", "250")) / 1000.0
QUEUE    = os.environ.get("SIM_QUEUE", "queue:sim")
FAKE     = os.environ.get("SIM_FAKE") == "1"          # local smoke tests only

VCAP_APP = json.loads(os.environ.get("VCAP_APPLICATION", "{}"))
APP      = VCAP_APP.get("application_name") or os.environ.get("SIM_APP", socket.gethostname())
INSTANCE = int(os.environ.get("CF_INSTANCE_INDEX", "0"))
STARTED  = datetime.now(timezone.utc).isoformat(timespec="seconds")

def now(): return datetime.now(timezone.utc).isoformat(timespec="seconds")
def dval(i):  # deterministic value for key i
    return hashlib.sha256(f"{APP}:{SEED}:{i}".encode()).hexdigest()[:32]

# ----------------------------------------------------------------------------- credentials
def resolve_credentials():
    """-> (host, port, password, username|None, source_label)"""
    if SOURCE == "env":
        return (os.environ["REDIS_HOST"], int(os.environ.get("REDIS_PORT", "6379")),
                os.environ.get("REDIS_PASSWORD", ""), os.environ.get("REDIS_USERNAME") or None, "env")
    vcap = json.loads(os.environ.get("VCAP_SERVICES", "{}"))
    for label, entries in vcap.items():
        is_ups = (label == "user-provided")
        if SOURCE == "ups" and not is_ups: continue
        if SOURCE == "vcap" and is_ups:   continue
        for e in entries:
            if SVC_NAME and e.get("name") != SVC_NAME: continue
            c = e.get("credentials") or {}
            if "host" in c and "password" in c:
                return (c["host"], int(c.get("port") or 6379), c["password"], c.get("username"),
                        f"{'ups' if is_ups else 'vcap'}:{e.get('name')}")
    raise RuntimeError(f"no credentials found (SIM_SOURCE={SOURCE}, SIM_SERVICE_NAME={SVC_NAME!r})")

HOST, PORT, PASSWORD, USERNAME, SOURCE_LABEL = resolve_credentials()
AUTH_STYLE = "username" if (AUTH == "username" and USERNAME) else "password"

def make_client():
    if FAKE:
        import fakeredis
        return fakeredis.FakeStrictRedis(server=_FAKE_SERVER, decode_responses=True)
    kw = dict(host=HOST, port=PORT, password=PASSWORD, decode_responses=True,
              socket_connect_timeout=3, socket_timeout=5, health_check_interval=15)
    if AUTH_STYLE == "username": kw["username"] = USERNAME
    return redis.Redis(**kw)

if FAKE:
    import fakeredis
    _FAKE_SERVER = fakeredis.FakeServer()
R = make_client()

# ----------------------------------------------------------------------------- stats
class Stats:
    def __init__(self):
        self.lock = threading.Lock(); self.ops = 0; self.errors = 0; self.reconnects = 0
        self.lat = deque(maxlen=200); self.last_error = ""; self.was_down = False
        self.m = {}   # mode-specific counters
    def op(self, ms):
        with self.lock:
            self.ops += 1; self.lat.append(ms)
            if self.was_down: self.reconnects += 1; self.was_down = False
    def err(self, e):
        with self.lock: self.errors += 1; self.last_error = str(e)[:200]; self.was_down = True
    def pct(self):
        with self.lock:
            if not self.lat: return {"p50": None, "p99": None}
            s = sorted(self.lat); return {"p50": round(s[len(s)//2], 2), "p99": round(s[int(len(s)*0.99)-1 if len(s) > 1 else 0], 2)}
S = Stats()

def timed(fn):
    t = time.perf_counter(); r = fn(); S.op((time.perf_counter() - t) * 1000); return r

# ----------------------------------------------------------------------------- canary
CANARY_KEY = f"canary:{APP}"
def ensure_canary():
    try:
        if not R.exists(CANARY_KEY): R.set(CANARY_KEY, now())
    except Exception as e: S.err(e)

# ----------------------------------------------------------------------------- mode workers
def work_cache():
    i = 0
    S.m.setdefault("hits", 0); S.m.setdefault("misses", 0)
    while True:
        try:
            k = f"cache:{APP}:{i % NKEYS}"
            v = timed(lambda: R.get(k))
            if v is None:
                S.m["misses"] += 1; timed(lambda: R.set(k, dval(i % NKEYS), ex=300))
            else: S.m["hits"] += 1
            i += 1
        except Exception as e: S.err(e)
        time.sleep(INTERVAL)

def session_key(): return f"session:{APP}:" + hashlib.sha256(f"{APP}:{SEED}:session".encode()).hexdigest()[:16]
def work_session():
    k = session_key()
    while True:
        try:
            if not timed(lambda: R.exists(k)):
                timed(lambda: R.set(k, json.dumps({"user": "sim", "minted": now()}), ex=86400)); S.m["reminted"] = S.m.get("reminted", 0) + 1
            else: timed(lambda: R.expire(k, 86400))
        except Exception as e: S.err(e)
        time.sleep(max(INTERVAL, 1.0))

def store_key(i): return f"store:{APP}:{i}"
def work_store():
    # seed once (never overwrite -- a copied dataset must survive), then just keep touching it
    try:
        p = R.pipeline()
        for i in range(NKEYS): p.set(store_key(i), dval(i), nx=True)
        timed(lambda: p.execute())
    except Exception as e: S.err(e)
    i = 0
    while True:
        try: timed(lambda: R.get(store_key(i % NKEYS))); i += 1
        except Exception as e: S.err(e)
        time.sleep(INTERVAL)

def work_producer():
    S.m.setdefault("pushed", 0)
    while True:
        try:
            seq = timed(lambda: R.incr(f"{QUEUE}:seq"))
            timed(lambda: R.rpush(QUEUE, json.dumps({"seq": seq, "ts": now(), "by": APP})))
            S.m["pushed"] += 1; S.m["last_seq"] = seq
        except Exception as e: S.err(e)
        time.sleep(INTERVAL)

def work_consumer():
    S.m.update({"consumed": 0, "gaps": 0, "duplicates": 0, "last_seq": None})
    while True:
        try:
            item = timed(lambda: R.blpop(QUEUE, timeout=2))
            if not item: continue
            seq = json.loads(item[1])["seq"]; last = S.m["last_seq"]
            if last is not None:
                if seq <= last: S.m["duplicates"] += 1
                elif seq > last + 1: S.m["gaps"] += 1; S.m["gap_size"] = S.m.get("gap_size", 0) + (seq - last - 1)
            S.m["last_seq"] = seq; S.m["consumed"] += 1
        except Exception as e: S.err(e); time.sleep(INTERVAL)

def work_lock():
    # A scheduled job that must run ONCE per 5-second window across all instances. Each window
    # has its own lock key; whoever wins runs the job. Two detectors:
    #  - double_exec: the in-store job counter > 1 (two holders on the SAME store)
    #  - runs[]: per-instance log of (window, ts) -- the verifier merges all instances' logs and
    #    finds windows run by >1 instance, which also catches the cutover case where instances
    #    restart at different times and briefly hold "the lock" on different stores.
    S.m.update({"acquired": 0, "jobs_run": 0, "double_exec": 0, "runs": []})
    token = str(uuid.uuid4())
    while True:
        try:
            window = int(time.time() // 5)
            if timed(lambda: R.set(f"lock:{APP}:{window}", token, nx=True, ex=10)):
                S.m["acquired"] += 1
                n = timed(lambda: R.incr(f"job:{APP}:{window}")); R.expire(f"job:{APP}:{window}", 60)
                S.m["jobs_run"] += 1
                if n > 1: S.m["double_exec"] += 1
                S.m["runs"] = (S.m["runs"] + [[window, now(), INSTANCE]])[-100:]
                time.sleep(1)                                    # "running the job"
        except Exception as e: S.err(e)
        time.sleep(INTERVAL)

WORKERS = {"cache": work_cache, "session": work_session, "store": work_store,
           "producer": work_producer, "consumer": work_consumer, "lock": work_lock}

# ----------------------------------------------------------------------------- /check pieces
def server_info():
    try:
        info = R.info("server")
        if "valkey_version" in info: return "valkey", str(info["valkey_version"])
        if "redis_version"  in info: return "redis",  str(info["redis_version"])
        return "unknown", ""
    except Exception as e: return "unknown", f"err: {e}"[:80]

def auth_user():
    try: return R.execute_command("ACL", "WHOAMI")
    except Exception: return "n/a"

def roundtrip():
    k = f"rt:{APP}:{uuid.uuid4().hex[:8]}"; t = time.perf_counter()
    R.set(k, "1", ex=10); assert R.get(k) == "1"; R.delete(k)
    return round((time.perf_counter() - t) * 1000, 2)

def families():
    out = {}; p = f"fam:{APP}"
    tests = {
        "string": lambda: (R.set(p+":s", "v", ex=30), R.get(p+":s")),
        "hash":   lambda: (R.hset(p+":h", "f", "v"), R.hget(p+":h", "f"), R.expire(p+":h", 30)),
        "list":   lambda: (R.rpush(p+":l", "a"), R.lpop(p+":l")),
        "zset":   lambda: (R.zadd(p+":z", {"m": 1}), R.zscore(p+":z", "m"), R.expire(p+":z", 30)),
        "eval":   lambda: R.eval("return redis.call('GET', KEYS[1])", 1, p+":s"),
        "multi":  lambda: R.pipeline(transaction=True).incr(p+":c").expire(p+":c", 30).execute(),
        "stream": lambda: (R.xadd(p+":x", {"k": "v"}, maxlen=10), R.xrange(p+":x", count=1)),
        "pubsub": lambda: R.publish(p+":ch", "ping"),
    }
    for name, fn in tests.items():
        try: fn(); out[name] = "ok"
        except Exception as e: out[name] = str(e)[:80]
    return out

def mode_data():
    d = dict(S.m)
    try:
        if MODE == "cache":
            sample = list(range(0, NKEYS, max(1, NKEYS // 20)))
            vals = R.mget([f"cache:{APP}:{i}" for i in sample])
            present = [(i, v) for i, v in zip(sample, vals) if v is not None]
            d.update({"keys": NKEYS, "sampled": len(present), "correct": sum(1 for i, v in present if v == dval(i))})
        elif MODE == "session":
            k = session_key(); d.update({"token_key": k, "present": bool(R.exists(k)), "ttl_s": R.ttl(k)})
        elif MODE == "store":
            vals = R.mget([store_key(i) for i in range(NKEYS)])
            found = sum(1 for v in vals if v is not None)
            h = hashlib.sha256("".join(v or "-" for v in vals).encode()).hexdigest()
            expected_h = hashlib.sha256("".join(dval(i) for i in range(NKEYS)).encode()).hexdigest()
            d.update({"expected": NKEYS, "found": found, "checksum_ok": (h == expected_h),
                      "missing_sample": [i for i, v in enumerate(vals) if v is None][:5]})
        elif MODE in ("producer", "consumer"):
            d.update({"queue": QUEUE, "queue_len": R.llen(QUEUE)})
    except Exception as e: d["error"] = str(e)[:120]
    return d

app = Flask(__name__)

@app.get("/healthz")
def healthz(): return "ok", 200

@app.get("/check")
def check():
    server, version = server_info()
    connected, rt, err = True, None, ""
    try: rt = roundtrip()
    except Exception as e: connected, err = False, str(e)[:200]
    canary = {"key": CANARY_KEY, "written_at": None, "present": False}
    try:
        v = R.get(CANARY_KEY); canary.update({"written_at": v, "present": v is not None})
    except Exception: pass
    return jsonify({
        "app": APP, "instance": INSTANCE, "mode": MODE, "expects": EXPECTS,
        "source": SOURCE_LABEL, "auth_style": AUTH_STYLE, "endpoint": f"{HOST}:{PORT}",
        "connected": connected, "server": server, "version": version, "auth_user": auth_user(),
        "roundtrip_ms": rt, "error": err or S.last_error,
        "families": families() if connected else {},
        "canary": canary,
        "since_start": {"ops": S.ops, "errors": S.errors, "reconnects": S.reconnects, "started_at": STARTED},
        "latency_ms": S.pct(),
        "mode_data": mode_data() if connected else {},
        "checked_at": now(),
    })

@app.get("/")
def root(): return jsonify({"app": APP, "mode": MODE, "see": "/check"})

if __name__ == "__main__":
    ensure_canary()
    threading.Thread(target=WORKERS[MODE], daemon=True).start()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), threaded=True)
