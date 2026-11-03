// Package xraytranslate converts a Clash YAML profile into per-node
// Xray-core JSON configs. Trial scope: vless, vmess, trojan and
// shadowsocks nodes in global mode (one mixed inbound, private ranges
// direct, everything else through the selected node). Hysteria2 and
// other types are reported as skipped rather than silently dropped.
package xraytranslate

import (
	"encoding/json"
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

type clashProxy struct {
	Name              string   `yaml:"name"`
	Type              string   `yaml:"type"`
	Server            string   `yaml:"server"`
	Port              int      `yaml:"port"`
	UUID              string   `yaml:"uuid"`
	Password          string   `yaml:"password"`
	Cipher            string   `yaml:"cipher"`
	AlterId           int      `yaml:"alterId"`
	Flow              string   `yaml:"flow"`
	Network           string   `yaml:"network"`
	TLS               bool     `yaml:"tls"`
	ServerName        string   `yaml:"servername"`
	SNI               string   `yaml:"sni"`
	ClientFingerprint string   `yaml:"client-fingerprint"`
	SkipCertVerify    bool     `yaml:"skip-cert-verify"`
	ALPN              []string `yaml:"alpn"`
	RealityOpts       struct {
		PublicKey string `yaml:"public-key"`
		ShortID   string `yaml:"short-id"`
	} `yaml:"reality-opts"`
	WSOpts struct {
		Path    string            `yaml:"path"`
		Headers map[string]string `yaml:"headers"`
	} `yaml:"ws-opts"`
	GRPCOpts struct {
		ServiceName string `yaml:"grpc-service-name"`
	} `yaml:"grpc-opts"`
}

type clashConfig struct {
	Proxies []clashProxy `yaml:"proxies"`
	Rules   []string     `yaml:"rules"`
}

type NodeInfo struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type SkippedNode struct {
	Name   string `json:"name"`
	Type   string `json:"type"`
	Reason string `json:"reason"`
}

type Result struct {
	Nodes        []NodeInfo        `json:"nodes"`
	Skipped      []SkippedNode     `json:"skipped"`
	Configs      map[string]string `json:"configs"`
	RulesApplied int               `json:"rulesApplied"`
	RulesSkipped int               `json:"rulesSkipped"`
}

var privateCIDRs = []string{
	"127.0.0.0/8",
	"10.0.0.0/8",
	"172.16.0.0/12",
	"192.168.0.0/16",
	"169.254.0.0/16",
	"::1/128",
	"fc00::/7",
	"fe80::/10",
}

func sniOf(p clashProxy) string {
	if p.SNI != "" {
		return p.SNI
	}
	return p.ServerName
}

func streamSettings(p clashProxy) map[string]any {
	network := p.Network
	if network == "" {
		network = "tcp"
	}
	stream := map[string]any{"network": network}
	fingerprint := p.ClientFingerprint
	if fingerprint == "" {
		fingerprint = "chrome"
	}
	switch {
	case p.RealityOpts.PublicKey != "":
		stream["security"] = "reality"
		stream["realitySettings"] = map[string]any{
			"serverName":  sniOf(p),
			"fingerprint": fingerprint,
			"publicKey":   p.RealityOpts.PublicKey,
			"shortId":     p.RealityOpts.ShortID,
			"spiderX":     "",
		}
	case p.TLS:
		stream["security"] = "tls"
		stream["tlsSettings"] = map[string]any{
			"serverName":    sniOf(p),
			"fingerprint":   fingerprint,
			"alpn":          p.ALPN,
			"allowInsecure": p.SkipCertVerify,
		}
	}
	switch network {
	case "ws":
		path := p.WSOpts.Path
		if path == "" {
			path = "/"
		}
		ws := map[string]any{"path": path}
		if len(p.WSOpts.Headers) > 0 {
			ws["headers"] = p.WSOpts.Headers
		}
		stream["wsSettings"] = ws
	case "grpc":
		stream["grpcSettings"] = map[string]any{
			"serviceName": p.GRPCOpts.ServiceName,
		}
	}
	return stream
}

func nodeOutbound(p clashProxy) (map[string]any, error) {
	switch strings.ToLower(p.Type) {
	case "vless":
		user := map[string]any{
			"id":         p.UUID,
			"encryption": "none",
		}
		if p.Flow != "" {
			user["flow"] = p.Flow
		}
		return map[string]any{
			"tag":      "proxy",
			"protocol": "vless",
			"settings": map[string]any{
				"vnext": []any{
					map[string]any{
						"address": p.Server,
						"port":    p.Port,
						"users":   []any{user},
					},
				},
			},
			"streamSettings": streamSettings(p),
		}, nil
	case "vmess":
		cipher := p.Cipher
		if cipher == "" {
			cipher = "auto"
		}
		return map[string]any{
			"tag":      "proxy",
			"protocol": "vmess",
			"settings": map[string]any{
				"vnext": []any{
					map[string]any{
						"address": p.Server,
						"port":    p.Port,
						"users": []any{
							map[string]any{
								"id":       p.UUID,
								"alterId":  p.AlterId,
								"security": cipher,
							},
						},
					},
				},
			},
			"streamSettings": streamSettings(p),
		}, nil
	case "trojan":
		q := p
		if !q.TLS && q.RealityOpts.PublicKey == "" {
			// Trojan runs over TLS by definition; Clash implies it.
			q.TLS = true
		}
		return map[string]any{
			"tag":      "proxy",
			"protocol": "trojan",
			"settings": map[string]any{
				"servers": []any{
					map[string]any{
						"address":  p.Server,
						"port":     p.Port,
						"password": p.Password,
					},
				},
			},
			"streamSettings": streamSettings(q),
		}, nil
	case "ss", "shadowsocks":
		return map[string]any{
			"tag":      "proxy",
			"protocol": "shadowsocks",
			"settings": map[string]any{
				"servers": []any{
					map[string]any{
						"address":  p.Server,
						"port":     p.Port,
						"method":   p.Cipher,
						"password": p.Password,
					},
				},
			},
		}, nil
	}
	return nil, fmt.Errorf("unsupported in xray trial")
}

type Options struct {
	VPN     bool
	LogPath string
	// Rules enables rule mode: the profile's own Clash rules are
	// translated into Xray routing rules (unsupported types dropped).
	// Without usable profile rules it falls back to the classic
	// bypass-mainland set (geosite:cn / geoip:cn direct). Rule mode
	// needs geoip.dat and geosite.dat in the Xray asset directory.
	Rules bool
}

// translateRule converts one Clash rule line into an Xray field rule.
// ok=false for rule types with no equivalent in this client. Named
// proxy groups collapse onto the single selected node's outbound.
func translateRule(line string) (map[string]any, bool) {
	parts := strings.Split(line, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	if len(parts) < 2 {
		return nil, false
	}
	outboundFor := func(target string) string {
		switch strings.ToUpper(target) {
		case "DIRECT":
			return "direct"
		case "REJECT":
			return "block"
		default:
			return "proxy"
		}
	}
	rule := map[string]any{"type": "field"}
	switch strings.ToUpper(parts[0]) {
	case "MATCH", "FINAL":
		// A field rule needs at least one effective field, or Xray
		// rejects the whole config at Start ("this rule has no
		// effective fields"). network tcp,udp matches everything,
		// which is exactly MATCH semantics, and keeps the target.
		rule["network"] = "tcp,udp"
		rule["outboundTag"] = outboundFor(parts[1])
		return rule, true
	case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "GEOSITE":
		if len(parts) < 3 {
			return nil, false
		}
		prefix := map[string]string{
			"DOMAIN":         "full:",
			"DOMAIN-SUFFIX":  "domain:",
			"DOMAIN-KEYWORD": "keyword:",
			"GEOSITE":        "geosite:",
		}[strings.ToUpper(parts[0])]
		rule["domain"] = []string{prefix + parts[1]}
		rule["outboundTag"] = outboundFor(parts[2])
		return rule, true
	case "IP-CIDR", "IP-CIDR6":
		if len(parts) < 3 {
			return nil, false
		}
		rule["ip"] = []string{parts[1]}
		rule["outboundTag"] = outboundFor(parts[2])
		return rule, true
	case "GEOIP":
		if len(parts) < 3 {
			return nil, false
		}
		rule["ip"] = []string{"geoip:" + strings.ToLower(parts[1])}
		rule["outboundTag"] = outboundFor(parts[2])
		return rule, true
	case "DST-PORT":
		if len(parts) < 3 {
			return nil, false
		}
		rule["port"] = parts[1]
		rule["outboundTag"] = outboundFor(parts[2])
		return rule, true
	}
	return nil, false
}

func buildConfig(p clashProxy, profileRules []string, opts Options) (string, error) {
	outbound, err := nodeOutbound(p)
	if err != nil {
		return "", err
	}
	logCfg := map[string]any{"loglevel": "warning", "access": "none"}
	if opts.LogPath != "" {
		logCfg["loglevel"] = "info"
		logCfg["error"] = opts.LogPath
	}
	inbounds := []any{
		map[string]any{
			"tag":      "in",
			"listen":   "127.0.0.1",
			"port":     7890,
			"protocol": "mixed",
			"sniffing": map[string]any{
				"enabled":      true,
				"destOverride": []string{"http", "tls"},
			},
		},
	}
	if opts.VPN {
		// The Android VpnService owns the TUN device; its fd reaches
		// the core through the xray.tun.fd environment variable, which
		// the tun inbound reads when the instance is created.
		inbounds = append(inbounds, map[string]any{
			"tag":      "tun",
			"protocol": "tun",
			"settings": map[string]any{
				"name": "xray0",
				"MTU":  1500,
			},
			"sniffing": map[string]any{
				"enabled":      true,
				"destOverride": []string{"http", "tls"},
			},
		})
	}
	routingRules := []any{}
	if opts.Rules {
		applied := 0
		for _, line := range profileRules {
			if r, ok := translateRule(line); ok {
				routingRules = append(routingRules, r)
				applied++
			}
		}
		if applied == 0 {
			// No usable rules in the profile: classic bypass-mainland.
			routingRules = append(routingRules,
				map[string]any{
					"type":        "field",
					"domain":      []string{"geosite:cn"},
					"outboundTag": "direct",
				},
				map[string]any{
					"type":        "field",
					"ip":          []string{"geoip:cn"},
					"outboundTag": "direct",
				},
			)
		}
	}
	routingRules = append(routingRules,
		map[string]any{
			"type":        "field",
			"ip":          privateCIDRs,
			"outboundTag": "direct",
		},
		map[string]any{
			"type":        "field",
			"inboundTag":  []string{"in", "tun"},
			"outboundTag": "proxy",
		},
	)
	cfg := map[string]any{
		"log":   logCfg,
		"stats": map[string]any{},
		"policy": map[string]any{
			"system": map[string]any{
				"statsOutboundUplink":   true,
				"statsOutboundDownlink": true,
			},
		},
		"inbounds": inbounds,
		"outbounds": []any{
			outbound,
			map[string]any{"tag": "direct", "protocol": "freedom"},
			map[string]any{"tag": "block", "protocol": "blackhole"},
		},
		"routing": map[string]any{
			"domainStrategy": "AsIs",
			"rules":          routingRules,
		},
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// Translate parses a Clash profile and builds one standalone Xray
// config per supported node (global mode, that node as the exit).
func Translate(clashYAML []byte, opts Options) (*Result, error) {
	var cfg clashConfig
	if err := yaml.Unmarshal(clashYAML, &cfg); err != nil {
		return nil, fmt.Errorf("parse clash yaml: %w", err)
	}
	if len(cfg.Proxies) == 0 {
		return nil, fmt.Errorf("no proxies in profile")
	}
	result := &Result{
		Nodes:   []NodeInfo{},
		Skipped: []SkippedNode{},
		Configs: map[string]string{},
	}
	if opts.Rules {
		for _, line := range cfg.Rules {
			if _, ok := translateRule(line); ok {
				result.RulesApplied++
			} else {
				result.RulesSkipped++
			}
		}
	}
	for _, p := range cfg.Proxies {
		nodeCfg, err := buildConfig(p, cfg.Rules, opts)
		if err != nil {
			reason := err.Error()
			if strings.Contains(reason, "unsupported") {
				reason = "xray 试用版暂不支持此类型"
			}
			result.Skipped = append(result.Skipped, SkippedNode{
				Name:   p.Name,
				Type:   p.Type,
				Reason: reason,
			})
			continue
		}
		result.Nodes = append(result.Nodes, NodeInfo{Name: p.Name, Type: p.Type})
		result.Configs[p.Name] = nodeCfg
	}
	if len(result.Nodes) == 0 {
		return nil, fmt.Errorf("no node usable by xray in this profile")
	}
	return result, nil
}

type AllResult struct {
	Config string         `json:"config"`
	Ports  map[string]int `json:"ports"`
}

// TranslateAll builds ONE Xray config holding every supported node as
// its own outbound, each fronted by a dedicated mixed inbound on
// 127.0.0.1:20100+i. It exists for parallel latency tests: a single
// core instance can probe all nodes at once instead of restarting
// per node.
func TranslateAll(clashYAML []byte, logPath string) (*AllResult, error) {
	var cfg clashConfig
	if err := yaml.Unmarshal(clashYAML, &cfg); err != nil {
		return nil, fmt.Errorf("parse clash yaml: %w", err)
	}
	if len(cfg.Proxies) == 0 {
		return nil, fmt.Errorf("no proxies in profile")
	}
	outbounds := []any{}
	inbounds := []any{}
	rules := []any{}
	ports := map[string]int{}
	idx := 0
	for _, p := range cfg.Proxies {
		outbound, err := nodeOutbound(p)
		if err != nil {
			continue
		}
		outTag := fmt.Sprintf("proxy-%d", idx)
		outbound["tag"] = outTag
		outbounds = append(outbounds, outbound)
		port := 20100 + idx
		inTag := fmt.Sprintf("in-%d", idx)
		inbounds = append(inbounds, map[string]any{
			"tag":      inTag,
			"listen":   "127.0.0.1",
			"port":     port,
			"protocol": "mixed",
			"sniffing": map[string]any{
				"enabled":      true,
				"destOverride": []string{"http", "tls"},
			},
		})
		rules = append(rules, map[string]any{
			"type":        "field",
			"inboundTag":  []string{inTag},
			"outboundTag": outTag,
		})
		ports[p.Name] = port
		idx++
	}
	if idx == 0 {
		return nil, fmt.Errorf("no node usable by xray in this profile")
	}
	outbounds = append(outbounds,
		map[string]any{"tag": "direct", "protocol": "freedom"},
		map[string]any{"tag": "block", "protocol": "blackhole"},
	)
	logCfg := map[string]any{"loglevel": "warning", "access": "none"}
	if logPath != "" {
		logCfg["error"] = logPath
	}
	full := map[string]any{
		"log":       logCfg,
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"routing": map[string]any{
			"domainStrategy": "AsIs",
			"rules":          rules,
		},
	}
	raw, err := json.Marshal(full)
	if err != nil {
		return nil, err
	}
	return &AllResult{Config: string(raw), Ports: ports}, nil
}
