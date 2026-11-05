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

// Rule mode is the original v2ray bypass-mainland preset, not a
// translation of the profile's Clash rules (that translation was
// lossy and left domestic apps without network).
func TestRulesModePreset(t *testing.T) {
	res, err := Translate([]byte(sampleRulesYAML), Options{Rules: true})
	if err != nil {
		t.Fatal(err)
	}
	if res.RulesApplied != 2 {
		t.Fatalf("applied=%d, want 2 (preset entries)", res.RulesApplied)
	}
	cfg := res.Configs["n1"]
	for _, want := range []string{
		`"domainStrategy":"IPIfNonMatch"`,
		`"geosite:cn"`,
		`"geoip:cn"`,
		`"address":"223.5.5.5"`,
		`"skipFallback":true`,
		`"tag":"direct-dns"`,
		`"https://8.8.8.8/dns-query"`,
		`"domainStrategy":"UseIP"`,
		`"sockopt":{"domainStrategy":"UseIP"}`,
		`"port":"53"`,
		`"protocol":"dns"`,
	} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("rules-mode config missing %s\n%s", want, cfg)
		}
	}
	for _, notWant := range []string{
		`"domain:google.com"`, // profile rules must NOT be translated
		`"full:api.example.com"`,
		`"geosite:category-ads-all"`,
	} {
		if strings.Contains(cfg, notWant) {
			t.Fatalf("rules-mode config must not contain %s\n%s", notWant, cfg)
		}
	}
	res2, err := Translate([]byte(sampleRulesYAML), Options{Rules: false})
	if err != nil {
		t.Fatal(err)
	}
	cfg2 := res2.Configs["n1"]
	if !strings.Contains(cfg2, `"domainStrategy":"AsIs"`) {
		t.Fatalf("global mode must stay AsIs\n%s", cfg2)
	}
	if strings.Contains(cfg2, `"ip":["geoip:cn"]`) {
		t.Fatalf("global mode must not contain the routing preset\n%s", cfg2)
	}
	if !strings.Contains(cfg2, `"https://8.8.8.8/dns-query"`) {
		t.Fatalf("global mode must still carry the DNS plan\n%s", cfg2)
	}
}
