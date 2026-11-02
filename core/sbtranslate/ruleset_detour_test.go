package sbtranslate

import (
	"strings"
	"testing"
)

// Regression: GEOIP rules became remote rule-sets fetched from
// raw.githubusercontent.com, which is unreachable directly from the
// user's network; with download_detour=direct the fetch failed at Box
// Start and the whole engine refused to start. The detour must be the
// route's final outbound (the proxy selector).
func TestRuleSetDetourUsesFinalOutbound(t *testing.T) {
	yaml := `
proxies:
  - name: N1
    type: ss
    server: 192.0.2.1
    port: 8388
    cipher: aes-256-gcm
    password: secret
proxy-groups:
  - name: PROXY
    type: select
    proxies: [N1, DIRECT]
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
`
	cfg, err := ParseClash([]byte(yaml))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Translate(cfg)
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	if !strings.Contains(s, `"download_detour": "PROXY"`) {
		t.Fatalf("rule-set detour is not the final outbound:\n%s", s)
	}
	if strings.Contains(s, `"download_detour": "direct"`) {
		t.Fatalf("rule-set still detours direct:\n%s", s)
	}
}
