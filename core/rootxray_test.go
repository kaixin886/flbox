package main

import (
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"

	xcore "github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

// rootTestYAML is the shared two-node fixture for the root
// mode config builders: node-a is addressed by domain (its
// bootstrap DNS entry is asserted), node-b by IP literal.
// It lived in rootconfig_test.go until 0.68 removed the
// TUN builder and its tests.
const rootTestYAML = `
proxies:
  - name: node-a
    type: vless
    server: a.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: 0123456789abcdef
  - name: node-b
    type: vless
    server: 203.0.113.7
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: 0123456789abcdef
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - node-a
      - node-b
rules:
  - MATCH,PROXY
`

func parseRootXray(t *testing.T, node string) map[string]any {
	t.Helper()
	out, err := rootXrayConfig(rootTestYAML, node, routeGlobal, false, false)
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
	if dns["tag"] != "proxy-dns" {
		t.Errorf("dns tag = %v, routing pins queries by it", dns["tag"])
	}
	if dns["queryStrategy"] != "UseIPv4" {
		t.Errorf("queryStrategy = %v, want UseIPv4 with IPv6 off", dns["queryStrategy"])
	}
	servers := dns["servers"].([]any)
	if len(servers) != 2 {
		t.Fatalf("dns servers = %v, want direct + DoH", servers)
	}
	direct := servers[0].(map[string]any)
	domains := direct["domains"].([]any)
	if direct["address"] != "223.5.5.5" ||
		direct["tag"] != "direct-dns" ||
		direct["skipFallback"] != true ||
		len(domains) != 2 || domains[0] != "geosite:cn" ||
		domains[1] != "domain:a.example.com" {
		t.Errorf("direct server wrong (gated domestic server for CN + node domain): %v", direct)
	}
	if servers[1] != "https://8.8.8.8/dns-query" {
		t.Errorf("second server = %v, want the DoH proxy server", servers[1])
	}
	// Without sockopt.domainStrategy the core resolves
	// the node domain through the OS resolver and the
	// daemon dies on netd's refused [::1]:53 (0.66).
	proxy := cfg["outbounds"].([]any)[0].(map[string]any)
	sockopt := proxy["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
	if sockopt["domainStrategy"] != "UseIPv4" {
		t.Errorf("proxy outbound sockopt = %v, want domainStrategy UseIPv4", sockopt)
	}
	// The direct outbound needs the same treatment: it
	// dials sniffed domain destinations (wx.qlogo.cn),
	// and OS-resolver lookups for those died on the
	// same netd refusal in the 2026-11-05 device log.
	for _, ob := range cfg["outbounds"].([]any) {
		o := ob.(map[string]any)
		if o["tag"] != "direct" {
			continue
		}
		so := o["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
		if so["domainStrategy"] != "UseIPv4" {
			t.Errorf("direct outbound sockopt = %v, want domainStrategy UseIPv4 with IPv6 off", so)
		}
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
	if len(servers) != 2 {
		t.Fatalf("dns servers = %v, want direct + DoH", servers)
	}
	domains := servers[0].(map[string]any)["domains"].([]any)
	if len(domains) != 1 || domains[0] != "geosite:cn" {
		t.Errorf("IP-addressed node adds no domain to the direct server: %v", domains)
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
	if assets := os.Getenv("FLBOX_TEST_ASSETS"); assets != "" {
		os.Setenv("xray.location.asset", assets)
	}
	out, err := rootXrayConfig(rootTestYAML, "node-a", routeGlobal, false, false)
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

func parseRootXrayMode(t *testing.T, node string, mode int) map[string]any {
	t.Helper()
	out, err := rootXrayConfig(rootTestYAML, node, mode, false, false)
	if err != nil {
		t.Fatalf("rootXrayConfig(%s, %d): %v", node, mode, err)
	}
	var cfg map[string]any
	if err := json.Unmarshal([]byte(out), &cfg); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestRootXrayShapeRules(t *testing.T) {
	cfg := parseRootXrayMode(t, "node-a", routeRules)
	routing := cfg["routing"].(map[string]any)
	if routing["domainStrategy"] != "IPIfNonMatch" {
		t.Errorf("rule mode needs IPIfNonMatch: %v", routing["domainStrategy"])
	}
	rules := routing["rules"].([]any)
	var sawGeosite, sawGeoip bool
	for _, r := range rules {
		rule := r.(map[string]any)
		if domains, ok := rule["domain"].([]any); ok && len(domains) > 0 && domains[0] == "geosite:cn" {
			sawGeosite = rule["outboundTag"] == "direct"
		}
		if ips, ok := rule["ip"].([]any); ok && len(ips) > 0 && ips[0] == "geoip:cn" {
			sawGeoip = rule["outboundTag"] == "direct"
		}
	}
	if !sawGeosite || !sawGeoip {
		t.Errorf("rule preset incomplete: geosite=%v geoip=%v in %v", sawGeosite, sawGeoip, rules)
	}
	servers := cfg["dns"].(map[string]any)["servers"].([]any)
	if len(servers) != 2 {
		t.Fatalf("rule mode dns servers = %v, want direct + DoH like every mode", servers)
	}
	cn := servers[0].(map[string]any)
	if cn["address"] != "223.5.5.5" || cn["domains"].([]any)[0] != "geosite:cn" {
		t.Errorf("first server must be the gated CN split: %v", cn)
	}
}

func TestRootXrayShapeDirect(t *testing.T) {
	cfg := parseRootXrayMode(t, "node-a", routeDirect)
	rules := cfg["routing"].(map[string]any)["rules"].([]any)
	last := rules[len(rules)-1].(map[string]any)
	if last["outboundTag"] != "direct" {
		t.Errorf("direct mode final rule = %v, want direct", last)
	}
	for _, r := range rules {
		rule := r.(map[string]any)
		if tags, ok := rule["inboundTag"].([]any); ok && len(tags) == 1 && tags[0] == "proxy-dns" {
			if rule["outboundTag"] != "direct" {
				t.Errorf("direct mode dns queries must exit direct: %v", rule)
			}
		}
	}
}
