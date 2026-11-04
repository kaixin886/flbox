package main

import (
	"encoding/json"
	"fmt"
	"net"

	"flbox/core/sbtranslate"
)

// rootTunConfig builds the sing-box configuration the root
// daemon (cmd/flboxd) runs for root TUN mode: the whole
// profile translated by sbtranslate with the selector preset
// to the chosen node, its inbound replaced by a TUN device
// the daemon owns as root (auto_route installs the system
// routes itself - no VpnService involved), and routing cut
// down to the global shape for this first stage: DNS is
// hijacked into the core, private ranges go direct,
// everything else leaves through the profile's final
// outbound (normally the group whose selector now defaults
// to the chosen node).
//
// The rule-mode preset the VPN path applies through Xray
// needs sing-box rule-sets (.srs) rather than the bundled
// .dat files, so it is a later stage; root TUN starts
// global-only on purpose.
//
// DNS is the bootstrap trap of every proxy core: the chosen
// node's server is usually a domain, and resolving it through
// the proxy it names would be circular. The bootstrap server
// therefore dials the system path directly - a new-style
// sing-box DNS server with no detour uses its own direct
// dialer; an explicit detour to a bare direct outbound is
// rejected as a no-op ("detour to an empty direct outbound
// makes no sense", reproduced locally 2026-11-04 after the
// 0.54 build failed on device in exactly that spot) - and
// gets a DNS rule for exactly that domain; ordinary queries
// use the remote server through the tunnel.
func rootTunConfig(clashYAML, selectedNode string, ipv6 bool, includePkgs, excludePkgs []string) (string, error) {
	cfg, err := sbtranslate.ParseClash([]byte(clashYAML))
	if err != nil {
		return "", err
	}
	var sel *sbtranslate.ClashProxy
	for i := range cfg.Proxies {
		if cfg.Proxies[i].Name == selectedNode {
			sel = &cfg.Proxies[i]
			break
		}
	}
	if sel == nil {
		return "", fmt.Errorf("node %q not in profile", selectedNode)
	}
	// Preset every group that contains the node so the
	// profile's routing final (its first group) lands on it.
	selected := map[string]string{}
	for _, g := range cfg.Groups {
		for _, m := range g.Proxies {
			if m == selectedNode {
				selected[g.Name] = selectedNode
			}
		}
	}
	raw, err := sbtranslate.TranslateWithOptions(cfg, sbtranslate.Options{Selected: selected})
	if err != nil {
		return "", err
	}
	var root map[string]any
	if err := json.Unmarshal(raw, &root); err != nil {
		return "", err
	}
	route, _ := root["route"].(map[string]any)
	if route == nil {
		route = map[string]any{}
	}
	final, _ := route["final"].(string)
	if len(selected) == 0 {
		// No group routes to this node: aim the final at the
		// node itself instead of the profile default.
		final = sbtranslate.TagForName(selectedNode)
	}
	if final == "" || final == "direct" || final == "block" {
		return "", fmt.Errorf("profile has no usable final outbound for root mode")
	}
	route["final"] = final
	route["rules"] = []any{
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
		map[string]any{"ip_is_private": true, "outbound": "direct"},
	}
	delete(route, "rule_set")
	root["route"] = route

	addrs := []any{"172.19.0.1/30"}
	if ipv6 {
		addrs = append(addrs, "fdfe:dcba:9876::1/126")
	}
	tun := map[string]any{
		"type":         "tun",
		"tag":          "tun-in",
		"address":      addrs,
		"mtu":          1500,
		"auto_route":   true,
		"strict_route": true,
		"stack":        "gvisor",
	}
	if len(includePkgs) > 0 {
		tun["include_package"] = anyStrings(includePkgs)
	}
	if len(excludePkgs) > 0 {
		tun["exclude_package"] = anyStrings(excludePkgs)
	}
	root["inbounds"] = []any{tun}

	dns := map[string]any{
		"servers": []any{
			map[string]any{
				"tag":    "dns-bootstrap",
				"type":   "udp",
				"server": "223.5.5.5",
			},
			map[string]any{
				"tag":    "dns-remote",
				"type":   "udp",
				"server": "8.8.8.8",
				"detour": final,
			},
		},
		"final": "dns-remote",
	}
	if sel.Server != "" && net.ParseIP(sel.Server) == nil {
		dns["rules"] = []any{
			map[string]any{
				"domain": []any{sel.Server},
				"action": "route",
				"server": "dns-bootstrap",
			},
		}
	}
	root["dns"] = dns

	out, err := json.Marshal(root)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func anyStrings(in []string) []any {
	out := make([]any, len(in))
	for i, s := range in {
		out[i] = s
	}
	return out
}
