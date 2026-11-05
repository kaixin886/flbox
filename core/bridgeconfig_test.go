package main

import (
	"encoding/json"
	"testing"
)

func TestBridgeXrayConfigsShape(t *testing.T) {
	out, err := bridgeXrayConfigs(rootTestYAML, "node-a", true, 1, []int{10123, 10456}, routeGlobal)
	if err != nil {
		t.Fatalf("bridgeXrayConfigs: %v", err)
	}
	var envelope map[string]string
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatal(err)
	}
	var core map[string]any
	if err := json.Unmarshal([]byte(envelope["core"]), &core); err != nil {
		t.Fatal(err)
	}
	// The daemon's core is Xray since 0.66: its JSON
	// carries "routing" and protocol-typed inbounds,
	// which is also how flboxd tells the flavors apart.
	if _, ok := core["routing"]; !ok {
		t.Fatalf("core config is not xray-flavored: %v", core)
	}
	inbounds := core["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatalf("core inbounds = %v, want one socks inbound", inbounds)
	}
	socks := inbounds[0].(map[string]any)
	if socks["protocol"] != "socks" || socks["port"] != float64(bridgeSocksPort) {
		t.Errorf("socks inbound wrong: %v", socks)
	}
	var bridge map[string]any
	if err := json.Unmarshal([]byte(envelope["bridge"]), &bridge); err != nil {
		t.Fatal(err)
	}
	if bridge["socksPort"] != float64(bridgeSocksPort) ||
		bridge["bridgePort"] != float64(bridgeListenPort) ||
		bridge["enableDnsHijack"] != true ||
		bridge["enableIpv6"] != true ||
		bridge["pinnedObjectDir"] != bridgePinnedDir {
		t.Errorf("bridge config wrong: %v", bridge)
	}
	// Token destinations span 127.128.0.0/9; a loopback-only
	// listener would never see a token connection (0.64).
	if bridge["bridgeListenAddress"] != "0.0.0.0" {
		t.Errorf("bridgeListenAddress = %v, want 0.0.0.0", bridge["bridgeListenAddress"])
	}
	policy := bridge["policy"].(map[string]any)
	if policy["mode"] != float64(1) || len(policy["uids"].([]any)) != 2 {
		t.Errorf("bridge policy wrong: %v", policy)
	}
	if _, err := bridgeFileConfig(false, 3, nil); err == nil {
		t.Errorf("mode 3 must be rejected")
	}
}
