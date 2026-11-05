package main

import (
	"encoding/json"
	"fmt"
	"net"

	"flbox/core/sbtranslate"
)

// eBPF mode (0.59): the daemon runs the same pinned-node
// sing-box as root TUN mode, but no TUN device exists.
// Traffic is steered in by netfilter rules the app installs
// (see MainActivity.netRules): TCP is REDIRECTed to the
// redirect inbound below; UDP is MARKed in OUTPUT, routed
// back over loopback and TPROXY'd in PREROUTING into the
// tproxy inbound (TPROXY is invalid in OUTPUT). The
// handshake with an app
// completes locally against the listener - it is never held
// hostage to the outbound dial the way the gVisor TUN stack
// holds it (the 0.58 "report handshake success: connection
// refused" failure class). The box's own dials carry
// route.default_mark, and the netfilter chains exempt that
// mark, so self-capture is impossible by construction - the
// netproxy/Asterisk structure. IPv6 is not steered in this
// stage; the app drops non-local v6 at the same chains
// instead of leaking it.
const (
	ebpfRedirectPort = 7892
	ebpfTproxyPort   = 7893
	// ebpfCoreMark stamps every outbound socket of the box;
	// the chains RETURN on it before any steering rule.
	ebpfCoreMark = 0x2B2B
)

func ebpfConfig(clashYAML, selectedNode string) (string, error) {
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
	// Same single-node strip as the 0.58 daemon config: no
	// groups, no urltest, the exit is the selected node.
	nodeTag := sbtranslate.TagForName(selectedNode)
	if outs, ok := root["outbounds"].([]any); ok {
		kept := make([]any, 0, 4)
		found := false
		for _, o := range outs {
			ob, _ := o.(map[string]any)
			if ob == nil {
				continue
			}
			tag, _ := ob["tag"].(string)
			typ, _ := ob["type"].(string)
			if tag == nodeTag {
				kept = append(kept, ob)
				found = true
			} else if typ == "direct" || typ == "block" {
				kept = append(kept, ob)
			}
		}
		if !found {
			return "", fmt.Errorf("selected node outbound missing after translation")
		}
		root["outbounds"] = kept
	}
	root["route"] = map[string]any{
		"final":                 nodeTag,
		"auto_detect_interface": true,
		"default_mark":          ebpfCoreMark,
		"rules": []any{
			map[string]any{"protocol": "dns", "action": "hijack-dns"},
			map[string]any{"ip_is_private": true, "outbound": "direct"},
		},
	}
	root["inbounds"] = []any{
		map[string]any{
			"type":        "redirect",
			"tag":         "redirect-in",
			"listen":      "127.0.0.1",
			"listen_port": ebpfRedirectPort,
		},
		map[string]any{
			"type":        "tproxy",
			"tag":         "tproxy-in",
			"listen":      "0.0.0.0",
			"listen_port": ebpfTproxyPort,
			"network":     "udp",
		},
	}
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
				"detour": nodeTag,
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
	root["log"] = map[string]any{"level": "info", "timestamp": true}

	out, err := json.Marshal(root)
	if err != nil {
		return "", err
	}
	return string(out), nil
}
