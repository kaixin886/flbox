package xraytranslate

import (
	"strings"
	"testing"
)

const sampleRulesYAML = `
proxies:
  - name: n1
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: pw
rules:
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN,api.example.com,DIRECT
  - GEOIP,CN,DIRECT
  - GEOSITE,category-ads-all,REJECT
  - IP-CIDR,1.2.3.0/24,PROXY,no-resolve
  - DST-PORT,443,DIRECT
  - PROCESS-NAME,foo,DIRECT
  - MATCH,PROXY
`

func TestRulesModeTranslation(t *testing.T) {
	res, err := Translate([]byte(sampleRulesYAML), Options{Rules: true})
	if err != nil {
		t.Fatal(err)
	}
	if res.RulesApplied != 7 || res.RulesSkipped != 1 {
		t.Fatalf("applied=%d skipped=%d, want 7/1", res.RulesApplied, res.RulesSkipped)
	}
	cfg := res.Configs["n1"]
	for _, want := range []string{
		`"domain:google.com"`,
		`"full:api.example.com"`,
		`"geoip:cn"`,
		`"geosite:category-ads-all"`,
		`"1.2.3.0/24"`,
		`"port":"443"`,
		`"outboundTag":"block"`,
	} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("config missing %s\n%s", want, cfg)
		}
	}
	res2, err := Translate([]byte(sampleRulesYAML), Options{Rules: false})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(res2.Configs["n1"], "geosite:") {
		t.Fatal("global mode must not contain geosite rules")
	}
}
