package main

import (
	"encoding/json"
	"strings"
	"testing"

	xcore "github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"

	"flbox/core/xraytranslate"
)

const smokeYAML = `
mixed-port: 7890
proxies:
  - name: NTT-Xray-443
    type: vless
    server: 203.0.113.10
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    flow: xtls-rprx-vision
    tls: true
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: abcd1234
  - name: SB-HY2
    type: hysteria2
    server: 203.0.113.10
    port: 443
    password: test-auth-secret
    obfs: salamander
    obfs-password: obfs-secret
    sni: www.apple.com
    up: 50
    down: 200
  - name: WG-TEST
    type: wireguard
    server: 203.0.113.20
    port: 51820
    private-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    public-key: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
    ip: 10.0.0.2
    mtu: 1280
rules:
  - MATCH,PROXY
`

func TestXraySmoke(t *testing.T) {
	result, err := xraytranslate.Translate([]byte(smokeYAML), xraytranslate.Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(result.Nodes) != 3 {
		t.Fatalf("nodes = %+v", result.Nodes)
	}
	if len(result.Skipped) != 0 {
		t.Fatalf("skipped = %+v", result.Skipped)
	}
	for name, cfgJSON := range result.Configs {
		if _, err := xcore.LoadConfig("json", strings.NewReader(cfgJSON)); err != nil {
			t.Errorf("node %s: config rejected by Xray: %v", name, err)
		}
	}
	cfgJSON := result.Configs["NTT-Xray-443"]
	var probe map[string]any
	if err := json.Unmarshal([]byte(cfgJSON), &probe); err != nil {
		t.Fatalf("config is not json: %v", err)
	}
	cfg, err := xcore.LoadConfig("json", strings.NewReader(cfgJSON))
	if err != nil {
		t.Fatalf("xray LoadConfig: %v", err)
	}
	if cfg == nil {
		t.Fatal("nil config")
	}
	t.Logf("xray version %s, config loads OK", xcore.Version())

	// The VPN variant (error log path; the tunnel itself is fed by
	// the sing-box forwarder, so no tun inbound) must parse too.
	vpnResult, err := xraytranslate.Translate([]byte(smokeYAML), xraytranslate.Options{
		VPN:     true,
		LogPath: "/tmp/xray-error.log",
	})
	if err != nil {
		t.Fatalf("vpn translate: %v", err)
	}
	for name, vpnCfg := range vpnResult.Configs {
		if strings.Contains(vpnCfg, `"protocol":"tun"`) {
			t.Errorf("node %s: vpn config must not carry a tun inbound", name)
		}
		if _, err := xcore.LoadConfig("json", strings.NewReader(vpnCfg)); err != nil {
			t.Errorf("node %s: vpn config rejected by Xray: %v", name, err)
		}
	}
}

const tlsYAML = `
proxies:
  - name: TLS-VLESS
    type: vless
    server: 203.0.113.30
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    tls: true
    servername: example.com
    skip-cert-verify: true
  - name: TLS-TROJAN
    type: trojan
    server: 203.0.113.31
    port: 443
    password: test-pass
    sni: example.com
    skip-cert-verify: true
  - name: HY2-SKIP
    type: hysteria2
    server: 203.0.113.32
    port: 443
    password: test-auth
    sni: example.com
    skip-cert-verify: true
`

// Plain-TLS nodes (the airport staple) must load: Xray removed
// allowInsecure and rejects any config still carrying the key,
// which used to break both starting on such a node and the
// all-node speed test.
func TestXrayTlsNodesLoad(t *testing.T) {
	result, err := xraytranslate.Translate([]byte(tlsYAML), xraytranslate.Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(result.Nodes) != 3 {
		t.Fatalf("nodes = %+v", result.Nodes)
	}
	for name, cfgJSON := range result.Configs {
		if strings.Contains(cfgJSON, "allowInsecure") {
			t.Errorf("node %s: config still carries allowInsecure", name)
		}
		if _, err := xcore.LoadConfig("json", strings.NewReader(cfgJSON)); err != nil {
			t.Errorf("node %s: config rejected by Xray: %v", name, err)
		}
	}
}
