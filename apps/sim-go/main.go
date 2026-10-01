// sim -- the Redis->Valkey migration probe app (Go port of apps/sim-py, same CHECK-CONTRACT.md).
// Static binary, pushed with binary_buildpack: no buildpack downloads, works air-gapped, and
// the same code cross-compiles for Windows cells. Config via env: SIM_MODE
// (cache|session|store|producer|consumer|lock), SIM_SOURCE (vcap|env|ups), SIM_AUTH
// (password|username), SIM_SERVICE_NAME, SIM_EXPECTS, SIM_SEED, SIM_KEYS, SIM_INTERVAL_MS,
// SIM_QUEUE, SIM_TLS=1 (connect to tls_port), REDIS_HOST/PORT/PASSWORD/USERNAME (SIM_SOURCE=env).
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

type App struct {
	Name, Mode, Source, SourceLabel, AuthStyle, Expects, Queue string
	Instance, Seed, NKeys                                      int
	Interval                                                   time.Duration
	Host                                                       string
	Port                                                       int
	Password, Username                                         string
	TLS                                                        bool
	R                                                          *redis.Client
	Started                                                    string

	mu         sync.Mutex
	ops, errs  int
	reconnects int
	wasDown    bool
	lastErr    string
	lat        []float64
	m          map[string]any
	runs       [][]any
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func envInt(k string, d int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return d
}
func now() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

func (a *App) dval(i int) string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:%d", a.Name, a.Seed, i)))
	return hex.EncodeToString(h[:])[:32]
}

// ---------------------------------------------------------------- credentials
type cred struct {
	Host, Password, Username string
	Port, TLSPort            int
}

func asInt(v any) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(t)
		return n
	}
	return 0
}

func resolveCredentials(source, svcName string) (cred, string, error) {
	if source == "env" {
		return cred{Host: os.Getenv("REDIS_HOST"), Port: envInt("REDIS_PORT", 6379), TLSPort: envInt("REDIS_TLS_PORT", 0),
			Password: os.Getenv("REDIS_PASSWORD"), Username: os.Getenv("REDIS_USERNAME")}, "env", nil
	}
	var vcap map[string][]struct {
		Name        string         `json:"name"`
		Credentials map[string]any `json:"credentials"`
	}
	if err := json.Unmarshal([]byte(env("VCAP_SERVICES", "{}")), &vcap); err != nil {
		return cred{}, "", fmt.Errorf("VCAP_SERVICES: %v", err)
	}
	for label, entries := range vcap {
		isUPS := label == "user-provided"
		if (source == "ups") != isUPS {
			continue
		}
		for _, e := range entries {
			if svcName != "" && e.Name != svcName {
				continue
			}
			c := e.Credentials
			host, _ := c["host"].(string)
			pw, _ := c["password"].(string)
			if host == "" || c["password"] == nil {
				continue
			}
			user, _ := c["username"].(string)
			port := asInt(c["port"])
			if port == 0 {
				port = 6379
			}
			kind := "vcap"
			if isUPS {
				kind = "ups"
			}
			return cred{Host: host, Port: port, TLSPort: asInt(c["tls_port"]), Password: pw, Username: user}, kind + ":" + e.Name, nil
		}
	}
	return cred{}, "", fmt.Errorf("no credentials found (SIM_SOURCE=%s SIM_SERVICE_NAME=%q)", source, svcName)
}

func buildApp() (*App, error) {
	a := &App{Mode: env("SIM_MODE", "cache"), Source: env("SIM_SOURCE", "vcap"), Expects: os.Getenv("SIM_EXPECTS"),
		Seed: envInt("SIM_SEED", 1), Queue: env("SIM_QUEUE", "queue:sim"), Instance: envInt("CF_INSTANCE_INDEX", 0),
		Interval: time.Duration(envInt("SIM_INTERVAL_MS", 250)) * time.Millisecond, Started: now(), m: map[string]any{},
		TLS: os.Getenv("SIM_TLS") == "1"}
	a.NKeys = envInt("SIM_KEYS", map[bool]int{true: 1000, false: 200}[a.Mode == "store"])
	var vapp struct {
		ApplicationName string `json:"application_name"`
	}
	_ = json.Unmarshal([]byte(env("VCAP_APPLICATION", "{}")), &vapp)
	a.Name = vapp.ApplicationName
	if a.Name == "" {
		h, _ := os.Hostname()
		a.Name = env("SIM_APP", h)
	}
	c, label, err := resolveCredentials(a.Source, os.Getenv("SIM_SERVICE_NAME"))
	if err != nil {
		return nil, err
	}
	a.SourceLabel, a.Host, a.Port, a.Password, a.Username = label, c.Host, c.Port, c.Password, c.Username
	if a.TLS && c.TLSPort > 0 {
		a.Port = c.TLSPort
	}
	a.AuthStyle = "password"
	if env("SIM_AUTH", "username") == "username" && a.Username != "" {
		a.AuthStyle = "username"
	}
	opt := &redis.Options{Addr: fmt.Sprintf("%s:%d", a.Host, a.Port), Password: a.Password,
		DialTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, PoolSize: 4}
	if a.AuthStyle == "username" {
		opt.Username = a.Username
	}
	if a.TLS {
		opt.TLSConfig = &tls.Config{InsecureSkipVerify: os.Getenv("SIM_TLS_VERIFY") != "1"} // platform-internal CA; verify opt-in
	}
	a.R = redis.NewClient(opt)
	return a, nil
}

// ---------------------------------------------------------------- stats
func (a *App) timed(f func() error) error {
	t := time.Now()
	err := f()
	a.mu.Lock()
	defer a.mu.Unlock()
	if err != nil {
		a.errs++
		a.lastErr = err.Error()
		if len(a.lastErr) > 200 {
			a.lastErr = a.lastErr[:200]
		}
		a.wasDown = true
		return err
	}
	a.ops++
	if a.wasDown {
		a.reconnects++
		a.wasDown = false
	}
	a.lat = append(a.lat, float64(time.Since(t).Microseconds())/1000)
	if len(a.lat) > 200 {
		a.lat = a.lat[1:]
	}
	return nil
}
func (a *App) inc(k string, d int) { a.mu.Lock(); a.m[k] = toInt(a.m[k]) + d; a.mu.Unlock() }
func (a *App) set(k string, v any) { a.mu.Lock(); a.m[k] = v; a.mu.Unlock() }
func toInt(v any) int {
	if i, ok := v.(int); ok {
		return i
	}
	return 0
}
func (a *App) pct() map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.lat) == 0 {
		return map[string]any{"p50": nil, "p99": nil}
	}
	s := append([]float64{}, a.lat...)
	sort.Float64s(s)
	i99 := int(float64(len(s))*0.99) - 1
	if i99 < 0 {
		i99 = 0
	}
	return map[string]any{"p50": round(s[len(s)/2]), "p99": round(s[i99])}
}
func round(f float64) float64 { return float64(int(f*100)) / 100 }

// ---------------------------------------------------------------- workers
var ctx = context.Background()

func (a *App) canaryKey() string { return "canary:" + a.Name }
func (a *App) ensureCanary() {
	_ = a.timed(func() error { return a.R.SetNX(ctx, a.canaryKey(), now(), 0).Err() })
}
func (a *App) sessionKey() string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:session", a.Name, a.Seed)))
	return "session:" + a.Name + ":" + hex.EncodeToString(h[:])[:16]
}
func (a *App) storeKey(i int) string { return fmt.Sprintf("store:%s:%d", a.Name, i) }

func (a *App) workCache() {
	for i := 0; ; i++ {
		k := fmt.Sprintf("cache:%s:%d", a.Name, i%a.NKeys)
		var v string
		err := a.timed(func() error { r, e := a.R.Get(ctx, k).Result(); v = r; if e == redis.Nil { v = ""; return nil }; return e })
		if err == nil {
			if v == "" {
				a.inc("misses", 1)
				_ = a.timed(func() error { return a.R.Set(ctx, k, a.dval(i%a.NKeys), 300*time.Second).Err() })
			} else {
				a.inc("hits", 1)
			}
		}
		time.Sleep(a.Interval)
	}
}
func (a *App) workSession() {
	k := a.sessionKey()
	for {
		var n int64
		if a.timed(func() error { r, e := a.R.Exists(ctx, k).Result(); n = r; return e }) == nil {
			if n == 0 {
				_ = a.timed(func() error {
					return a.R.Set(ctx, k, fmt.Sprintf(`{"user":"sim","minted":"%s"}`, now()), 86400*time.Second).Err()
				})
				a.inc("reminted", 1)
			} else {
				_ = a.timed(func() error { return a.R.Expire(ctx, k, 86400*time.Second).Err() })
			}
		}
		time.Sleep(max(a.Interval, time.Second))
	}
}
func (a *App) workStore() {
	_ = a.timed(func() error { // seed once, never overwrite: a copied dataset must survive
		p := a.R.Pipeline()
		cmds := make([]*redis.BoolCmd, a.NKeys)
		for i := 0; i < a.NKeys; i++ {
			cmds[i] = p.SetNX(ctx, a.storeKey(i), a.dval(i), 0)
		}
		_, e := p.Exec(ctx)
		if e == nil { // keys created NOW = keys that were missing when this process started
			n := 0
			for _, c := range cmds {
				if c.Val() {
					n++
				}
			}
			a.set("seeded_at_start", n) // 0 = dataset was already there (survived / copied); N = recreated
		}
		return e
	})
	for i := 0; ; i++ {
		_ = a.timed(func() error { _, e := a.R.Get(ctx, a.storeKey(i%a.NKeys)).Result(); if e == redis.Nil { return nil }; return e })
		time.Sleep(a.Interval)
	}
}
func (a *App) workProducer() {
	for {
		var seq int64
		if a.timed(func() error { r, e := a.R.Incr(ctx, a.Queue+":seq").Result(); seq = r; return e }) == nil {
			if a.timed(func() error {
				return a.R.RPush(ctx, a.Queue, fmt.Sprintf(`{"seq":%d,"ts":"%s","by":"%s"}`, seq, now(), a.Name)).Err()
			}) == nil {
				a.inc("pushed", 1)
				a.set("last_seq", int(seq))
			}
		}
		time.Sleep(a.Interval)
	}
}
func (a *App) workConsumer() {
	a.set("consumed", 0); a.set("gaps", 0); a.set("duplicates", 0); a.set("last_seq", nil)
	for {
		var item []string
		err := a.timed(func() error { r, e := a.R.BLPop(ctx, 2*time.Second, a.Queue).Result(); item = r; if e == redis.Nil { item = nil; return nil }; return e })
		if err != nil {
			time.Sleep(a.Interval)
			continue
		}
		if item == nil {
			continue
		}
		var msg struct{ Seq int }
		_ = json.Unmarshal([]byte(item[1]), &msg)
		a.mu.Lock()
		if last, ok := a.m["last_seq"].(int); ok {
			if msg.Seq <= last {
				a.m["duplicates"] = toInt(a.m["duplicates"]) + 1
			} else if msg.Seq > last+1 {
				a.m["gaps"] = toInt(a.m["gaps"]) + 1
				a.m["gap_size"] = toInt(a.m["gap_size"]) + (msg.Seq - last - 1)
			}
		}
		a.m["last_seq"] = msg.Seq
		a.m["consumed"] = toInt(a.m["consumed"]) + 1
		a.mu.Unlock()
	}
}
func (a *App) workLock() {
	// a job that must run ONCE per 5-second window across all instances: per-window lock keys;
	// double_exec = in-store counter >1 (two holders on the same store); runs[] = per-instance
	// log so the verifier can find windows run by >1 instance even across a store switch.
	a.set("acquired", 0); a.set("jobs_run", 0); a.set("double_exec", 0)
	token := uuid.NewString()
	for {
		w := time.Now().Unix() / 5
		var got bool
		if a.timed(func() error { r, e := a.R.SetNX(ctx, fmt.Sprintf("lock:%s:%d", a.Name, w), token, 10*time.Second).Result(); got = r; return e }) == nil && got {
			a.inc("acquired", 1)
			var n int64
			jk := fmt.Sprintf("job:%s:%d", a.Name, w)
			if a.timed(func() error { r, e := a.R.Incr(ctx, jk).Result(); n = r; return e }) == nil {
				a.R.Expire(ctx, jk, 60*time.Second)
				a.inc("jobs_run", 1)
				if n > 1 {
					a.inc("double_exec", 1)
				}
				a.mu.Lock()
				a.runs = append(a.runs, []any{w, now(), a.Instance})
				if len(a.runs) > 100 {
					a.runs = a.runs[1:]
				}
				a.mu.Unlock()
			}
			time.Sleep(time.Second)
		}
		time.Sleep(a.Interval)
	}
}

// ---------------------------------------------------------------- /check pieces
func (a *App) serverInfo() (string, string) {
	info, err := a.R.Info(ctx, "server").Result()
	if err != nil {
		return "unknown", "err: " + err.Error()
	}
	for _, line := range strings.Split(info, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "valkey_version:") {
			return "valkey", strings.TrimPrefix(line, "valkey_version:")
		}
	}
	for _, line := range strings.Split(info, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "redis_version:") {
			return "redis", strings.TrimPrefix(line, "redis_version:")
		}
	}
	return "unknown", ""
}
func (a *App) authUser() string {
	r, err := a.R.Do(ctx, "ACL", "WHOAMI").Result()
	if err != nil {
		return "n/a"
	}
	return fmt.Sprint(r)
}
func (a *App) roundtrip() (float64, error) {
	k := "rt:" + a.Name + ":" + uuid.NewString()[:8]
	t := time.Now()
	if err := a.R.Set(ctx, k, "1", 10*time.Second).Err(); err != nil {
		return 0, err
	}
	if v, err := a.R.Get(ctx, k).Result(); err != nil || v != "1" {
		return 0, fmt.Errorf("get mismatch: %v", err)
	}
	a.R.Del(ctx, k)
	return round(float64(time.Since(t).Microseconds()) / 1000), nil
}
func (a *App) families() map[string]string {
	p := "fam:" + a.Name
	tests := []struct {
		n string
		f func() error
	}{
		{"string", func() error { return a.R.Set(ctx, p+":s", "v", 30*time.Second).Err() }},
		{"hash", func() error { return a.R.HSet(ctx, p+":h", "f", "v").Err() }},
		{"list", func() error { return a.R.RPush(ctx, p+":l", "a").Err() }},
		{"zset", func() error { return a.R.ZAdd(ctx, p+":z", redis.Z{Score: 1, Member: "m"}).Err() }},
		{"eval", func() error { return a.R.Eval(ctx, "return redis.call('GET', KEYS[1])", []string{p + ":s"}).Err() }},
		{"multi", func() error { tx := a.R.TxPipeline(); tx.Incr(ctx, p+":c"); tx.Expire(ctx, p+":c", 30*time.Second); _, e := tx.Exec(ctx); return e }},
		{"stream", func() error { return a.R.XAdd(ctx, &redis.XAddArgs{Stream: p + ":x", MaxLen: 10, Values: map[string]any{"k": "v"}}).Err() }},
		{"pubsub", func() error { return a.R.Publish(ctx, p+":ch", "ping").Err() }},
	}
	out := map[string]string{}
	for _, t := range tests {
		if err := t.f(); err != nil && err != redis.Nil {
			out[t.n] = err.Error()
			if len(out[t.n]) > 80 {
				out[t.n] = out[t.n][:80]
			}
		} else {
			out[t.n] = "ok"
		}
	}
	for _, k := range []string{":h", ":l", ":z"} {
		a.R.Expire(ctx, p+k, 30*time.Second)
	}
	return out
}
func (a *App) modeData() map[string]any {
	a.mu.Lock()
	d := map[string]any{}
	for k, v := range a.m {
		d[k] = v
	}
	if a.Mode == "lock" {
		d["runs"] = append([][]any{}, a.runs...)
	}
	a.mu.Unlock()
	switch a.Mode {
	case "cache":
		step := max(1, a.NKeys/20)
		var keys []string
		var idx []int
		for i := 0; i < a.NKeys; i += step {
			keys = append(keys, fmt.Sprintf("cache:%s:%d", a.Name, i))
			idx = append(idx, i)
		}
		vals, err := a.R.MGet(ctx, keys...).Result()
		if err == nil {
			sampled, correct := 0, 0
			for j, v := range vals {
				if s, ok := v.(string); ok {
					sampled++
					if s == a.dval(idx[j]) {
						correct++
					}
				}
			}
			d["keys"], d["sampled"], d["correct"] = a.NKeys, sampled, correct
		}
	case "session":
		k := a.sessionKey()
		n, _ := a.R.Exists(ctx, k).Result()
		ttl, _ := a.R.TTL(ctx, k).Result()
		d["token_key"], d["present"], d["ttl_s"] = k, n > 0, int(ttl.Seconds())
	case "store":
		keys := make([]string, a.NKeys)
		for i := range keys {
			keys[i] = a.storeKey(i)
		}
		vals, err := a.R.MGet(ctx, keys...).Result()
		if err == nil {
			found, hExp, hGot := 0, sha256.New(), sha256.New()
			var missing []int
			for i, v := range vals {
				hExp.Write([]byte(a.dval(i)))
				if s, ok := v.(string); ok {
					found++
					hGot.Write([]byte(s))
				} else {
					hGot.Write([]byte("-"))
					if len(missing) < 5 {
						missing = append(missing, i)
					}
				}
			}
			d["expected"], d["found"], d["missing_sample"] = a.NKeys, found, missing
			d["checksum_ok"] = hex.EncodeToString(hExp.Sum(nil)) == hex.EncodeToString(hGot.Sum(nil))
		}
	case "producer", "consumer":
		n, _ := a.R.LLen(ctx, a.Queue).Result()
		d["queue"], d["queue_len"] = a.Queue, n
	}
	return d
}

func (a *App) check(w http.ResponseWriter, _ *http.Request) {
	server, version := a.serverInfo()
	connected, errS := true, ""
	rt, err := a.roundtrip()
	var rtv any = rt
	if err != nil {
		connected, rtv, errS = false, nil, err.Error()
	}
	canary := map[string]any{"key": a.canaryKey(), "written_at": nil, "present": false, "survived_restart": false}
	if v, e := a.R.Get(ctx, a.canaryKey()).Result(); e == nil {
		canary["written_at"], canary["present"] = v, true
		canary["survived_restart"] = v < a.Started // written before this process started => data outlived the restart
	}
	a.mu.Lock()
	ss := map[string]any{"ops": a.ops, "errors": a.errs, "reconnects": a.reconnects, "started_at": a.Started}
	if errS == "" {
		errS = a.lastErr
	}
	a.mu.Unlock()
	out := map[string]any{
		"app": a.Name, "instance": a.Instance, "mode": a.Mode, "expects": a.Expects, "source": a.SourceLabel,
		"auth_style": a.AuthStyle, "endpoint": fmt.Sprintf("%s:%d", a.Host, a.Port), "tls": a.TLS,
		"connected": connected, "server": server, "version": version, "auth_user": a.authUser(),
		"roundtrip_ms": rtv, "error": errS, "families": map[string]string{}, "canary": canary,
		"since_start": ss, "latency_ms": a.pct(), "mode_data": map[string]any{}, "checked_at": now(),
	}
	if connected {
		out["families"] = a.families()
		out["mode_data"] = a.modeData()
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (a *App) startWorker() {
	a.ensureCanary()
	switch a.Mode {
	case "cache":
		go a.workCache()
	case "session":
		go a.workSession()
	case "store":
		go a.workStore()
	case "producer":
		go a.workProducer()
	case "consumer":
		go a.workConsumer()
	case "lock":
		go a.workLock()
	}
}

func main() {
	a, err := buildApp()
	if err != nil {
		fmt.Fprintln(os.Stderr, "sim:", err)
		os.Exit(1)
	}
	a.startWorker()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/check", a.check)
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"app":%q,"mode":%q,"see":"/check"}`, a.Name, a.Mode)
	})
	fmt.Printf("sim %s mode=%s endpoint=%s:%d source=%s auth=%s\n", a.Name, a.Mode, a.Host, a.Port, a.SourceLabel, a.AuthStyle)
	_ = http.ListenAndServe(":"+env("PORT", "8080"), mux)
}
