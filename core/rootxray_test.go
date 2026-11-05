package main

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	xcore "github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

func parseRootXray(t *testing.T, node string) map[string]any {
	t.Helper()
	out, err := rootXrayConfig(rootTestYAML, node)
	if err != nil {
		t.Fatalf("rootXrayConfig(%s): %v", node, err)
	}
	var cfg map[string]any
	if err := json.Unmarshal([]byte(out), &cfg); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestRootXrayShapeDomainNode(t *testing.T) {
	cfg := parseRootXray(t, "node-a")
	inbounds := cfg["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatalf("inbounds = %v, want the bridge socks inbound only", inbounds)
	}
	in := inbounds[0].(map[string]any)
	if in["protocol"] != "socks" || in["port"] != float64(bridgeSocksPort) ||
		in["tag"] != rootXraySocksTag {
		t.Errorf("inbound wrong: %v", in)
	}
	if in["settings"].(map[string]any)["udp"] != true {
		t.Errorf("socks inbound must accept UDP for the bridge: %v", in)
	}
	dns := cfg["dns"].(map[string]any)
	if dns["tag"] != "dns" {
		t.Errorf("dns tag = %v, routing pins queries by it", dns["tag"])
	}
	servers := dns["servers"].([]any)
	if len(servers) != 2 {
		t.Fatalf("dns servers = %v, want bootstrap + remote", servers)
	}
	boot := servers[0].(map[string]any)
	if boot["address"] != "223.5.5.5" ||
		boot["domains"].([]any)[0] != "full:a.example.com" {
		t.Errorf("bootstrap server wrong: %v", boot)
	}
	if servers[1] != "8.8.8.8" {
		t.Errorf("remote server = %v, want 8.8.8.8", servers[1])
	}
	rules := cfg["routing"].(map[string]any)["rules"].([]any)
	first := rules[0].(map[string]any)
	if first["port"] != "53" || first["outboundTag"] != "dns" {
		t.Errorf("first rule must hijack DNS to the dns outbound: %v", first)
	}
	var tags []string
	for _, ob := range cfg["outbounds"].([]any) {
		tags = append(tags, ob.(map[string]any)["tag"].(string))
	}
	if tags[0] != "proxy" || tags[len(tags)-1] != "dns" {
		t.Errorf("outbound order wrong (proxy first, dns last): %v", tags)
	}
}

func TestRootXrayShapeIPNode(t *testing.T) {
	cfg := parseRootXray(t, "node-b")
	servers := cfg["dns"].(map[string]any)["servers"].([]any)
	if len(servers) != 1 || servers[0] != "8.8.8.8" {
		t.Errorf("IP-addressed node needs no bootstrap server: %v", servers)
	}
}

func TestRootXrayStarts(t *testing.T) {
	// The suite also runs inside a network namespace whose
	// loopback is down; there the dial check cannot work
	// and only the config-acceptance half matters.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("loopback unavailable here: %v", err)
	}
	self, err := net.DialTimeout("tcp", probe.Addr().String(), 200*time.Millisecond)
	if err != nil {
		probe.Close()
		t.Skipf("loopback dial unavailable here: %v", err)
	}
	self.Close()
	probe.Close()
	out, err := rootXrayConfig(rootTestYAML, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	inst, err := xcore.StartInstance("json", []byte(out))
	if err != nil {
		t.Fatalf("xray rejected the root config: %v", err)
	}
	defer inst.Close()
	deadline := time.Now().Add(3 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", "127.0.0.1:7891", 200*time.Millisecond)
		if err == nil {
			conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("socks inbound never listened: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
