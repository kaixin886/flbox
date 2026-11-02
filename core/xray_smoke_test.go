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
    password: placeholder
rules:
  - MATCH,PROXY
`

func TestXraySmoke(t *testing.T) {
	result, err := xraytranslate.Translate([]byte(smokeYAML))
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if len(result.Nodes) != 1 || result.Nodes[0].Name != "NTT-Xray-443" {
		t.Fatalf("nodes = %+v", result.Nodes)
	}
	if len(result.Skipped) != 1 || result.Skipped[0].Name != "SB-HY2" {
		t.Fatalf("skipped = %+v", result.Skipped)
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
}
