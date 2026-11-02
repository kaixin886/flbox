package sbtranslate

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Options carries runtime intent that is not part of the profile file:
// the user's current per-group selections (from setupConfig's
// selected-map) and the app-level skip-cert-verify toggle.
type Options struct {
	Selected       map[string]string
	SkipCertVerify bool
}

// Translate converts a parsed Clash profile into sing-box JSON config bytes.
// The output is a plain JSON document meant to be unmarshalled into
// sing-box's option.Options by the host; keeping it as bytes lets this
// package stay dependency-light and unit-testable.
func Translate(cfg *ClashConfig) ([]byte, error) {
	return TranslateWithOptions(cfg, Options{})
}

func TranslateWithOptions(cfg *ClashConfig, opts Options) ([]byte, error) {
	t := &builder{tags: map[string]bool{}, opts: opts}
	out := map[string]any{
		"log": map[string]any{"level": "warn", "timestamp": true},
	}

	// ---- outbounds: proxies first, then groups (groups reference proxies)
	var outbounds []any
	for i := range cfg.Proxies {
		ob, err := t.proxyOutbound(&cfg.Proxies[i])
		if err != nil {
			return nil, err
		}
		outbounds = append(outbounds, ob)
	}
	var firstGroupTag string
	for i := range cfg.Groups {
		ob, err := t.groupOutbound(&cfg.Groups[i])
		if err != nil {
			return nil, err
		}
		if firstGroupTag == "" {
			firstGroupTag = cfg.Groups[i].Name
		}
		outbounds = append(outbounds, ob)
	}
	outbounds = append(outbounds,
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "block", "tag": "block"},
	)
	out["outbounds"] = outbounds

	// ---- inbounds: one mixed (socks+http) inbound, Clash port semantics
	port := cfg.MixedPort
	if port == 0 {
		port = cfg.Port
	}
	if port == 0 {
		port = cfg.SocksPort
	}
	if port != 0 {
		out["inbounds"] = []any{
			map[string]any{
				"type":        "mixed",
				"tag":         "mixed-in",
				"listen":      "127.0.0.1",
				"listen_port": port,
			},
		}
	}

	// ---- dns: map nameservers in order, final = first
	if cfg.DNS != nil && cfg.DNS.Enable && len(cfg.DNS.Nameserver) > 0 {
		dns, err := translateDNS(cfg.DNS)
		if err != nil {
			return nil, err
		}
		out["dns"] = dns
	}

	// ---- route: clash rules -> sing-box route rules; MATCH sets final
	route, final, ruleSets := translateRules(cfg.Rules)
	if len(ruleSets) > 0 {
		route["rule_set"] = ruleSets
	}
	if final == "" {
		final = firstGroupTag
	}
	if final == "" && len(cfg.Proxies) > 0 {
		final = cfg.Proxies[0].Name
	}
	if final == "" {
		final = "direct"
	}
	route["final"] = final
	// In rule mode, unmatched traffic goes to final; in global mode the UI
	// expects everything via the selector, which `final` already expresses
	// for milestone A (selector default). Direct mode:
	if strings.EqualFold(cfg.Mode, "direct") {
		route["final"] = "direct"
	}
	// Remote rule-sets are fetched at Box Start and a failed fetch aborts
	// the start; their canonical host is unreachable directly from the
	// user's network, so fetch through the final outbound instead.
	if f, _ := route["final"].(string); f != "" && f != "direct" && f != "block" {
		if sets, ok := route["rule_set"].([]any); ok {
			for _, s := range sets {
				if m, ok := s.(map[string]any); ok {
					m["download_detour"] = f
				}
			}
		}
	}
	out["route"] = route

	return json.MarshalIndent(out, "", "  ")
}

type builder struct {
	tags map[string]bool
	opts Options
}

// tag maps a Clash-side name to the sing-box outbound tag for it.
// Clash profiles reference the built-ins DIRECT and REJECT by those
// names in group members, rule targets and MATCH; sing-box outbound
// tags for them are "direct" and "block". Everything else (proxy and
// group names) passes through unchanged.
func tag(name string) string {
	switch name {
	case "DIRECT":
		return "direct"
	case "REJECT":
		return "block"
	}
	return name
}

// TagForName exposes tag() to engine code that looks Box outbounds up by
// the Clash-side name Dart sent; NameForTag inverts it so a pick read back
// off the Box is reported in Clash vocabulary.
func TagForName(name string) string { return tag(name) }

func NameForTag(t string) string {
	switch t {
	case "direct":
		return "DIRECT"
	case "block":
		return "REJECT"
	}
	return t
}

func (t *builder) proxyOutbound(p *ClashProxy) (map[string]any, error) {
	switch strings.ToLower(p.Type) {
	case "vless":
		ob := map[string]any{
			"type":        "vless",
			"tag":         p.Name,
			"server":      p.Server,
			"server_port": p.Port,
			"uuid":        p.UUID,
		}
		if p.Flow != "" {
			ob["flow"] = p.Flow
		}
		if tls := t.tlsBlock(p, false); tls != nil {
			ob["tls"] = tls
		}
		return ob, nil
	case "hysteria2", "hy2":
		ob := map[string]any{
			"type":        "hysteria2",
			"tag":         p.Name,
			"server":      p.Server,
			"server_port": p.Port,
			"password":    p.Password,
		}
		if mbps, ok := parseMbps(p.Up); ok {
			ob["up_mbps"] = mbps
		}
		if mbps, ok := parseMbps(p.Down); ok {
			ob["down_mbps"] = mbps
		}
		ob["tls"] = t.tlsBlock(p, true) // hysteria2 is always TLS
		return ob, nil
	case "ss", "shadowsocks":
		return map[string]any{
			"type":        "shadowsocks",
			"tag":         p.Name,
			"server":      p.Server,
			"server_port": p.Port,
			"method":      p.Method,
			"password":    p.Password,
		}, nil
	case "trojan":
		ob := map[string]any{
			"type":        "trojan",
			"tag":         p.Name,
			"server":      p.Server,
			"server_port": p.Port,
			"password":    p.Password,
		}
		ob["tls"] = t.tlsBlock(p, true) // trojan is always TLS
		return ob, nil
	case "direct":
		return map[string]any{"type": "direct", "tag": p.Name}, nil
	default:
		return nil, fmt.Errorf("proxy %q: type %q not supported in stage-1 translator yet", p.Name, p.Type)
	}
}

// tlsBlock builds a sing-box TLS outbound block from Clash fields.
// force is for protocols that are always TLS (hysteria2, trojan): without
// it, a node whose Clash entry omits "tls: true" would silently lose its
// insecure / alpn / pin fields. Returns nil only for plaintext protocols
// with TLS off.
func (t *builder) tlsBlock(p *ClashProxy, force bool) map[string]any {
	if !force && !p.TLS && p.RealityOpts == nil {
		return nil
	}
	tls := map[string]any{"enabled": true}
	if sn := p.serverName(); sn != "" {
		tls["server_name"] = sn
	}
	if p.SkipCertVerify || t.opts.SkipCertVerify {
		tls["insecure"] = true
	}
	if pin := pinBase64(p.PinSHA256); pin != "" {
		tls["certificate_public_key_sha256"] = pin
	}
	if len(p.ALPN) > 0 {
		tls["alpn"] = p.ALPN
	}
	if p.ClientFingerprint != "" {
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": p.ClientFingerprint}
	}
	if p.RealityOpts != nil {
		tls["reality"] = map[string]any{
			"enabled":    true,
			"public_key": p.RealityOpts.PublicKey,
			"short_id":   p.RealityOpts.ShortID,
		}
		// REALITY requires uTLS in sing-box; default to chrome when unset.
		if _, ok := tls["utls"]; !ok {
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": "chrome"}
		}
	}
	return tls
}

func (t *builder) groupOutbound(g *ClashGroup) (map[string]any, error) {
	members := make([]string, len(g.Proxies))
	for i, name := range g.Proxies {
		members[i] = tag(name)
	}
	switch strings.ToLower(g.Type) {
	case "select":
		ob := map[string]any{
			"type":      "selector",
			"tag":       g.Name,
			"outbounds": members,
		}
		if len(members) > 0 {
			ob["default"] = members[0]
			if sel, ok := t.opts.Selected[g.Name]; ok {
				if mapped := tag(sel); contains(members, mapped) {
					ob["default"] = mapped
				}
			}
		}
		return ob, nil
	case "url-test", "fallback":
		// sing-box has urltest; fallback groups degrade to urltest in v1
		// (ordering preference is preserved via member order).
		ob := map[string]any{
			"type":      "urltest",
			"tag":       g.Name,
			"outbounds": members,
		}
		if g.URL != "" {
			ob["url"] = g.URL
		}
		if g.Interval > 0 {
			ob["interval"] = strconv.Itoa(g.Interval) + "s"
			// sing-box rejects a urltest whose interval exceeds its
			// idle_timeout (default 30m) at Start; Clash profiles freely
			// use hour-plus intervals, so raise idle_timeout to match.
			idle := g.Interval
			if idle < 1800 {
				idle = 1800
			}
			ob["idle_timeout"] = strconv.Itoa(idle) + "s"
		}
		return ob, nil
	default:
		return nil, fmt.Errorf("proxy group %q: type %q not supported in stage-1 translator yet", g.Name, g.Type)
	}
}

func translateDNS(d *ClashDNS) (map[string]any, error) {
	var servers []any
	var domainServers []map[string]any
	bootstrap := ""
	for i, ns := range d.Nameserver {
		srv, isDomain, err := dnsServer(ns, fmt.Sprintf("dns-%d", i))
		if err != nil {
			return nil, err
		}
		servers = append(servers, srv)
		if isDomain {
			domainServers = append(domainServers, srv)
		} else if bootstrap == "" {
			bootstrap = srv["tag"].(string)
		}
	}
	// sing-box >= 1.12 refuses a domain-addressed DNS server without an
	// explicit domain_resolver; mihomo bootstraps implicitly. Point such
	// servers at the first IP-literal server, or at a system-local one
	// when the profile has none.
	if len(domainServers) > 0 {
		if bootstrap == "" {
			bootstrap = "dns-bootstrap"
			servers = append(servers, map[string]any{"type": "local", "tag": bootstrap})
		}
		for _, srv := range domainServers {
			srv["domain_resolver"] = bootstrap
		}
	}
	return map[string]any{
		"servers": servers,
		"final":   "dns-0",
	}, nil
}

// dnsServer maps a Clash nameserver string to a sing-box 1.14 DNS server,
// reporting whether the server address is a domain (needs domain_resolver).
// Supported: plain IP (udp/53), https://host[/path], tls://host, dhcp://...
// No detour is emitted: 1.14's typed servers build their dialer without
// the default outbound, so an unset detour already dials directly — and
// naming the plain direct outbound trips its empty-direct guard at
// Start ("detour to an empty direct outbound makes no sense").
func dnsServer(ns, tag string) (map[string]any, bool, error) {
	switch {
	case strings.HasPrefix(ns, "https://"):
		host := strings.TrimPrefix(ns, "https://")
		server, path, _ := strings.Cut(host, "/")
		srv := map[string]any{"type": "https", "tag": tag, "server": server}
		if path != "" {
			srv["path"] = "/" + path
		}
		return srv, !isIP(server), nil
	case strings.HasPrefix(ns, "tls://"):
		server := strings.TrimPrefix(ns, "tls://")
		return map[string]any{"type": "tls", "tag": tag, "server": server}, !isIP(server), nil
	case strings.HasPrefix(ns, "dhcp://"):
		return map[string]any{"type": "dhcp", "tag": tag, "interface": strings.TrimPrefix(ns, "dhcp://")}, false, nil
	default:
		host := ns
		if h, _, found := strings.Cut(ns, "#"); found {
			host = h
		}
		return map[string]any{"type": "udp", "tag": tag, "server": host}, !isIP(host), nil
	}
}

func isIP(host string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return net.ParseIP(host) != nil
}

// translateRules converts Clash rule strings. Returns the route object
// (without "final"), the MATCH/FINAL target if one was present, and any
// remote rule-set definitions the rules referenced. REJECT targets become
// sing-box route rule action "reject" (1.14-native; the legacy block
// outbound is intentionally not emitted). GEOIP/GEOSITE become rule_set
// references: the inline fields were removed in sing-box 1.12, which the
// official-load validation test caught on first run.
func translateRules(rules []string) (map[string]any, string, []any) {
	var out []any
	final := ""
	ruleSets := map[string]any{}
	addRuleSet := func(kind, code string) string {
		tag := kind + "-" + code
		if _, ok := ruleSets[tag]; !ok {
			ruleSets[tag] = map[string]any{
				"tag":             tag,
				"type":            "remote",
				"format":          "binary",
				"url":             "https://raw.githubusercontent.com/SagerNet/sing-" + kind + "/rule-set/" + tag + ".srs",
				"download_detour": "direct",
			}
		}
		return tag
	}
	for _, raw := range rules {
		parts := strings.Split(strings.TrimSpace(raw), ",")
		if len(parts) < 2 {
			continue
		}
		typ := strings.ToUpper(parts[0])
		if typ == "MATCH" || typ == "FINAL" {
			final = tag(parts[1])
			continue
		}
		if len(parts) < 3 {
			continue
		}
		value, target := parts[1], parts[2]
		rule := map[string]any{}
		switch typ {
		case "DOMAIN":
			rule["domain"] = []string{value}
		case "DOMAIN-SUFFIX":
			rule["domain_suffix"] = []string{value}
		case "DOMAIN-KEYWORD":
			rule["domain_keyword"] = []string{value}
		case "IP-CIDR", "IP-CIDR6":
			rule["ip_cidr"] = []string{value}
		case "SRC-IP-CIDR":
			rule["source_ip_cidr"] = []string{value}
		case "GEOIP":
			rule["rule_set"] = []string{addRuleSet("geoip", strings.ToLower(value))}
		case "GEOSITE":
			rule["rule_set"] = []string{addRuleSet("geosite", strings.ToLower(value))}
		case "DST-PORT":
			if n, err := strconv.Atoi(value); err == nil {
				rule["port"] = []int{n}
			}
		case "PROCESS-NAME":
			rule["process_name"] = []string{value}
		default:
			// Unsupported rule types are skipped but not fatal: Clash
			// rule semantics for them (e.g. RULE-SET, AND/OR logic) need
			// dedicated work; milestone B. Skipping is visible via tests
			// on fixture profiles, never applied to proxy definitions.
			continue
		}
		if strings.EqualFold(target, "REJECT") || strings.EqualFold(target, "REJECT-DROP") {
			rule["action"] = "reject"
		} else {
			rule["outbound"] = tag(target)
		}
		out = append(out, rule)
	}
	route := map[string]any{}
	if len(out) > 0 {
		route["rules"] = out
	}
	sets := make([]any, 0, len(ruleSets))
	for _, def := range ruleSets {
		sets = append(sets, def)
	}
	return route, final, sets
}

// pinBase64 normalises a Clash pinSHA256 value to the base64 form
// sing-box expects for certificate_public_key_sha256. Clash clients carry
// the pin either as colon-separated hex ("61:06:F6:...") or as base64.
// Returns "" when the value is empty or unparseable (caller then omits it).
func pinBase64(pin string) string {
	pin = strings.TrimSpace(pin)
	if pin == "" {
		return ""
	}
	if strings.Contains(pin, ":") {
		raw, err := hex.DecodeString(strings.ReplaceAll(pin, ":", ""))
		if err == nil && len(raw) == 32 {
			return base64.StdEncoding.EncodeToString(raw)
		}
		return ""
	}
	if raw, err := hex.DecodeString(pin); err == nil && len(raw) == 32 {
		return base64.StdEncoding.EncodeToString(raw)
	}
	if raw, err := base64.StdEncoding.DecodeString(pin); err == nil && len(raw) == 32 {
		return pin
	}
	return ""
}

// parseMbps parses Clash bandwidth strings like "100 Mbps" / "1 Gbps".
func parseMbps(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	f := strings.Fields(s)
	if len(f) == 0 {
		return 0, false
	}
	n, err := strconv.Atoi(f[0])
	if err != nil {
		return 0, false
	}
	if len(f) > 1 && strings.EqualFold(f[1], "Gbps") {
		n *= 1000
	}
	return n, true
}

func contains(list []string, v string) bool {
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}
