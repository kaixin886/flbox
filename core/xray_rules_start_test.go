package main

import (
	"testing"

	xcore "github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"

	"flbox/core/xraytranslate"
)

// Rules mode must survive a real Xray Start, not just translation:
// a Clash MATCH rule used to become a field rule with no effective
// fields, which Xray only rejects when the instance is created
// ("app/router: this rule has no effective fields"). Geodata-backed
// rule types (GEOIP/GEOSITE) stay out of this test so it does not
// depend on geoip.dat/geosite.dat being present.
const rulesStartYAML = `
proxies:
  - name: n1
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: pw
rules:
  - DOMAIN-SUFFIX,google.com,PROXY
  - IP-CIDR,1.2.3.0/24,DIRECT,no-resolve
  - MATCH,PROXY
`

func TestXrayRulesModeStarts(t *testing.T) {
	res, err := xraytranslate.Translate([]byte(rulesStartYAML), xraytranslate.Options{Rules: true})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	inst, err := xcore.StartInstance("json", []byte(res.Configs["n1"]))
	if err != nil {
		t.Fatalf("rules-mode config rejected at Start: %v", err)
	}
	if err := inst.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}
