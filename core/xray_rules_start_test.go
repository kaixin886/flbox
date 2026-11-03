package main

import (
	"os"
	"testing"

	xcore "github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"

	"flbox/core/xraytranslate"
)

// Real-Start coverage: Xray validates routing only when the
// instance is created, so translation-only tests are not enough
// (the rules-mode MATCH empty-field bug passed every translation
// check and only failed at Start on the device).
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

func TestXrayGlobalStarts(t *testing.T) {
	res, err := xraytranslate.Translate([]byte(rulesStartYAML), xraytranslate.Options{})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	inst, err := xcore.StartInstance("json", []byte(res.Configs["n1"]))
	if err != nil {
		t.Fatalf("global config rejected at Start: %v", err)
	}
	if err := inst.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

// The rules-mode preset references geosite:cn / geoip:cn, whose
// matchers load the dat files when the instance is created. Run
// with FLBOX_TEST_ASSETS=<dir containing geoip.dat/geosite.dat>
// to exercise the full Start; skipped otherwise.
func TestXrayRulesPresetStarts(t *testing.T) {
	assets := os.Getenv("FLBOX_TEST_ASSETS")
	if assets == "" {
		t.Skip("FLBOX_TEST_ASSETS not set; preset Start needs geoip.dat/geosite.dat")
	}
	os.Setenv("xray.location.asset", assets)
	res, err := xraytranslate.Translate([]byte(rulesStartYAML), xraytranslate.Options{Rules: true})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	inst, err := xcore.StartInstance("json", []byte(res.Configs["n1"]))
	if err != nil {
		t.Fatalf("rules-preset config rejected at Start: %v", err)
	}
	if err := inst.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}
