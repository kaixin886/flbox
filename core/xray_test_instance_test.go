package main

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"flbox/core/xraytranslate"
)

// The bulk speed test runs each node as a transient instance on
// its own port, concurrently, without touching the main
// instance. This test starts two nodes side by side (ports
// moved off 7890), checks both listeners answer, then stops
// them and checks the ports are released.
func TestXrayTestInstances(t *testing.T) {
	result, err := xraytranslate.Translate([]byte(smokeYAML), xraytranslate.Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	const portA, portB = 20299, 20298
	if err := xrayTestStart(result.Configs["NTT-Xray-443"], portA); err != nil {
		t.Fatalf("test start A: %v", err)
	}
	defer xrayTestStop(portA)
	if err := xrayTestStart(result.Configs["SB-HY2"], portB); err != nil {
		t.Fatalf("test start B: %v", err)
	}
	defer xrayTestStop(portB)

	for _, port := range []int{portA, portB} {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
		if err != nil {
			t.Fatalf("test instance on %d not listening: %v", port, err)
		}
		conn.Close()
	}
	// The main instance must be untouched by test instances.
	if status := xrayStatus(); !strings.Contains(status, "running=false") {
		t.Fatalf("main instance disturbed: %s", status)
	}

	if err := xrayTestStop(portA); err != nil {
		t.Fatalf("test stop A: %v", err)
	}
	if conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", portA), 500*time.Millisecond); err == nil {
		conn.Close()
		t.Fatalf("port %d still listening after stop", portA)
	}
	// Stopping an unknown port is a no-op, not an error.
	if err := xrayTestStop(20999); err != nil {
		t.Fatalf("stop of unknown port: %v", err)
	}
}

// A rule-mode single-node config carries geosite/geoip routing
// and split DNS. The test path must strip those sections: feed
// it a config whose geo references point at a list that does
// not exist - if the sections survived, StartInstance would
// fail resolving them (and pay for loading the geo data files
// even when they do exist).
func TestXrayTestStartStripsGeoSections(t *testing.T) {
	result, err := xraytranslate.Translate([]byte(smokeYAML), xraytranslate.Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal([]byte(result.Configs["NTT-Xray-443"]), &cfg); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}
	cfg["routing"] = map[string]any{
		"domainStrategy": "IPIfNonMatch",
		"rules": []any{
			map[string]any{
				"type":        "field",
				"domain":      []string{"geosite:definitely-not-a-real-list"},
				"outboundTag": "direct",
			},
		},
	}
	cfg["dns"] = map[string]any{
		"servers": []any{
			map[string]any{
				"address": "223.5.5.5",
				"domains": []string{"geosite:definitely-not-a-real-list"},
			},
		},
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}
	const port = 20297
	if err := xrayTestStart(string(raw), port); err != nil {
		t.Fatalf("test start with bogus geo sections: %v", err)
	}
	defer xrayTestStop(port)
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
	if err != nil {
		t.Fatalf("stripped test instance not listening: %v", err)
	}
	conn.Close()
}

// Starts must run concurrently: the registry lock guards only
// the map, never StartInstance. Launch several starts at once
// and require every one to land its own listening instance.
func TestXrayTestStartConcurrent(t *testing.T) {
	result, err := xraytranslate.Translate([]byte(smokeYAML), xraytranslate.Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	configs := []string{result.Configs["NTT-Xray-443"], result.Configs["SB-HY2"]}
	const base = 20290
	const n = 4
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = xrayTestStart(configs[i%len(configs)], base+i)
		}(i)
	}
	wg.Wait()
	for i := 0; i < n; i++ {
		port := base + i
		if errs[i] != nil {
			t.Fatalf("concurrent start on %d: %v", port, errs[i])
		}
		defer xrayTestStop(port)
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
		if err != nil {
			t.Fatalf("concurrent instance on %d not listening: %v", port, err)
		}
		conn.Close()
	}
}
