package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
)

func TestAllModes(t *testing.T) {
	mr := miniredis.RunT(t)
	host, port, _ := strings.Cut(mr.Addr(), ":")
	os.Setenv("SIM_SOURCE", "env"); os.Setenv("REDIS_HOST", host); os.Setenv("REDIS_PORT", port)
	os.Setenv("REDIS_PASSWORD", ""); os.Setenv("SIM_KEYS", "50"); os.Setenv("SIM_INTERVAL_MS", "10")
	for _, mode := range []string{"cache", "session", "store", "producer", "consumer", "lock"} {
		os.Setenv("SIM_MODE", mode); os.Setenv("SIM_APP", "t-"+mode)
		a, err := buildApp()
		if err != nil { t.Fatalf("%s: %v", mode, err) }
		a.startWorker()
		time.Sleep(1500 * time.Millisecond)
		rec := httptest.NewRecorder()
		a.check(rec, httptest.NewRequest("GET", "/check", nil))
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil { t.Fatalf("%s: bad json: %v", mode, err) }
		if out["connected"] != true { t.Fatalf("%s: not connected: %v", mode, out["error"]) }
		if out["canary"].(map[string]any)["present"] != true { t.Fatalf("%s: canary missing", mode) }
		md := out["mode_data"].(map[string]any)
		switch mode {
		case "cache":
			if md["correct"] != md["sampled"] || md["sampled"].(float64) == 0 { t.Fatalf("cache: %v", md) }
		case "store":
			if md["checksum_ok"] != true || md["found"].(float64) != 50 { t.Fatalf("store: %v", md) }
		case "session":
			if md["present"] != true { t.Fatalf("session: %v", md) }
		case "producer":
			if md["pushed"].(float64) < 10 { t.Fatalf("producer: %v", md) }
		case "lock":
			if md["double_exec"].(float64) != 0 || md["jobs_run"].(float64) < 1 { t.Fatalf("lock: %v", md) }
		}
		t.Logf("%-9s ok  ops=%v errors=%v mode_data=%v", mode, out["since_start"].(map[string]any)["ops"], out["since_start"].(map[string]any)["errors"], md)
	}
}
