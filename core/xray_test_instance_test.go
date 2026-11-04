package main

import (
	"fmt"
	"net"
	"strings"
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
