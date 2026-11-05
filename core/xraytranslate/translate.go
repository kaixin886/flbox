// Package xraytranslate converts a Clash YAML profile into per-node
// Xray-core JSON configs. Scope: vless, vmess, trojan, shadowsocks,
// hysteria2 and wireguard nodes (one mixed inbound, private ranges
// direct, everything else through the selected node). Types Xray
// does not have (tuic, anytls, ...) are reported as skipped rather
// than silently dropped.
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
	// Hysteria2 fields. Up/Down arrive as either a number (Mbps) or
	// a string like "50 Mbps" depending on the provider.
	Obfs         string `yaml:"obfs"`
	ObfsPassword string `yaml:"obfs-password"`
	Auth         string `yaml:"auth"`
	Ports        string `yaml:"ports"`
	HopInterval  int    `yaml:"hop-interval"`
	Up           any    `yaml:"up"`
	Down         any    `yaml:"down"`
	// FlBox extension for locally created nodes: a SHA-256 cert pin
	// for self-signed servers (Xray dropped allowInsecure in favour
	// of pins). Subscriptions never carry it.
	PinnedCert string `yaml:"pinned-cert-sha256"`
	// WireGuard fields.
	PrivateKey   string   `yaml:"private-key"`
	PublicKey    string   `yaml:"public-key"`
	PreSharedKey string   `yaml:"pre-shared-key"`
	IP           string   `yaml:"ip"`
	IPv6         string   `yaml:"ipv6"`
	AllowedIPs   []string `yaml:"allowed-ips"`
	MTU          int      `yaml:"mtu"`
	Reserved     []int    `yaml:"reserved"`
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
		tlsSettings := map[string]any{
			"serverName":  sniOf(p),
			"fingerprint": fingerprint,
			"alpn":        p.ALPN,
		}
		// Never emit allowInsecure, in either value: Xray
		// removed the field and its mere presence in the JSON
		// is a hard config error ("The feature allowInsecure
		// has been removed"), which poisoned every plain-TLS
		// node - and any all-node speed-test config holding
		// one. Clash's skip-cert-verify has no Xray
		// equivalent; self-signed servers get pinned instead.
		if p.PinnedCert != "" {
			tlsSettings["pinnedPeerCertSha256"] = p.PinnedCert
		}
		stream["tlsSettings"] = tlsSettings
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

// bandwidthString normalises a Clash up/down value (number = Mbps,
// or a ready-made string) into the bandwidth string Xray parses.
func bandwidthString(v any) string {
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case int:
		return fmt.Sprintf("%d Mbps", t)
	case float64:
		return fmt.Sprintf("%v Mbps", t)
	}
	return ""
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
	case "hysteria2", "hy2":
		// Xray splits a hy2 client across two config blocks: the
		// outbound settings carry version/address/port, the auth
		// lives in the hysteria transport settings, obfs became a
		// finalmask (salamander) and bandwidth the finalmask's
		// quicParams (brutal); port hopping is the quicParams
		// udpHop port list.
		auth := p.Password
		if auth == "" {
			auth = p.Auth
		}
		fingerprint := p.ClientFingerprint
		if fingerprint == "" {
			fingerprint = "chrome"
		}
		alpn := p.ALPN
		if len(alpn) == 0 {
			alpn = []string{"h3"}
		}
		tlsSettings := map[string]any{
			"serverName":  sniOf(p),
			"fingerprint": fingerprint,
			"alpn":        alpn,
		}
		// allowInsecure is never emitted (see streamSettings).
		if p.PinnedCert != "" {
			tlsSettings["pinnedPeerCertSha256"] = p.PinnedCert
		}
		stream := map[string]any{
			"network":     "hysteria",
			"security":    "tls",
			"tlsSettings": tlsSettings,
			"hysteriaSettings": map[string]any{
				"version": 2,
				"auth":    auth,
			},
		}
		finalmask := map[string]any{}
		if strings.EqualFold(p.Obfs, "salamander") && p.ObfsPassword != "" {
			finalmask["udp"] = []any{
				map[string]any{
					"type":     "salamander",
					"settings": map[string]any{"password": p.ObfsPassword},
				},
			}
		}
		quicParams := map[string]any{}
		if up := bandwidthString(p.Up); up != "" {
			quicParams["brutalUp"] = up
		}
		if down := bandwidthString(p.Down); down != "" {
			quicParams["brutalDown"] = down
		}
		if p.Ports != "" {
			hop := map[string]any{"ports": p.Ports}
			if p.HopInterval > 0 {
				hop["interval"] = map[string]any{
					"from": p.HopInterval,
					"to":   p.HopInterval,
				}
			}
			quicParams["udpHop"] = hop
		}
		if len(quicParams) > 0 {
			finalmask["quicParams"] = quicParams
		}
		if len(finalmask) > 0 {
			stream["finalmask"] = finalmask
		}
		return map[string]any{
			"tag":      "proxy",
			"protocol": "hysteria",
			"settings": map[string]any{
				"version": 2,
				"address": p.Server,
				"port":    p.Port,
			},
			"streamSettings": stream,
		}, nil
	case "wireguard":
		addrs := []string{}
		for _, raw := range []string{p.IP, p.IPv6} {
			raw = strings.TrimSpace(raw)
			if raw == "" {
				continue
			}
			if !strings.Contains(raw, "/") {
				if strings.Contains(raw, ":") {
					raw += "/128"
				} else {
					raw += "/32"
				}
			}
			addrs = append(addrs, raw)
		}
		allowed := p.AllowedIPs
		if len(allowed) == 0 {
			allowed = []string{"0.0.0.0/0", "::/0"}
		}
		peer := map[string]any{
			"publicKey":  p.PublicKey,
			"endpoint":   fmt.Sprintf("%s:%d", p.Server, p.Port),
			"allowedIPs": allowed,
		}
		if p.PreSharedKey != "" {
			peer["preSharedKey"] = p.PreSharedKey
		}
		settings := map[string]any{
			"secretKey": p.PrivateKey,
			"address":   addrs,
			"peers":     []any{peer},
		}
		if p.MTU > 0 {
			settings["mtu"] = p.MTU
		}
		if len(p.Reserved) == 3 {
			settings["reserved"] = []byte{
				byte(p.Reserved[0]), byte(p.Reserved[1]), byte(p.Reserved[2]),
			}
		}
		return map[string]any{
			"tag":      "proxy",
			"protocol": "wireguard",
			"settings": settings,
		}, nil
	}
	return nil, fmt.Errorf("unsupported in xray trial")
}

type Options struct {
	VPN     bool
	LogPath string
	// Rules enables rule mode: the original v2ray bypass-mainland
	// preset (domainStrategy IPIfNonMatch, geosite:cn and geoip:cn
	// direct, everything else proxied, split DNS). The profile's own
	// Clash rules are NOT translated: Clash rule sets lean on
	// RULE-SET providers and Clash DNS semantics, and the lossy
	// translation left domestic apps without network. Rule mode
	// needs geoip.dat and geosite.dat in the Xray asset directory.
	Rules bool
	// Direct keeps the config's shape but exits everything
	// locally: the final routing rule points at the freedom
	// outbound, and neither the rules preset nor split DNS
	// applies. It wins over Rules if both are set.
	Direct bool
}

func buildConfig(p clashProxy, opts Options) (string, error) {
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
				"destOverride": []string{"http", "tls", "quic"},
			},
		},
	}
	// VPN mode deliberately gets no tun inbound any more: the
	// Android tunnel is owned by the sing-box forwarder, which feeds
	// this core through the mixed inbound (see vpnforward.go in the
	// core package). Xray's native tun stack dropped some apps'
	// connections mid-transfer on the user's phone. opts.VPN now
	// only records that the session runs behind the system tunnel.
	domainStrategy := "AsIs"
	routingRules := []any{}
	// Direct mode's only routing change: the final rule
	// exits through the freedom outbound instead of the node.
	finalTag := "proxy"
	if opts.Direct {
		finalTag = "direct"
	}
	if opts.Rules && !opts.Direct {
		// The v2ray preset: IPIfNonMatch is the load-bearing part.
		// With AsIs, a domain destination never reaches the IP
		// rules, so geoip:cn only fires for raw-IP traffic and most
		// domestic apps (domain-first) fall through to the proxy.
		// IPIfNonMatch resolves domains that matched no domain rule
		// and retries them against the IP rules, like stock v2ray.
		domainStrategy = "IPIfNonMatch"
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
	routingRules = append(routingRules,
		map[string]any{
			"type":        "field",
			"ip":          privateCIDRs,
			"outboundTag": "direct",
		},
		map[string]any{
			"type":        "field",
			"inboundTag":  []string{"in", "tun"},
			"outboundTag": finalTag,
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
			"domainStrategy": domainStrategy,
			"rules":          routingRules,
		},
	}
	if opts.Rules && !opts.Direct {
		// Split DNS, v2rayNG-style: CN domains resolve locally
		// (and must come back with CN IPs), the rest through the
		// proxied resolver. IPIfNonMatch's internal resolutions
		// go through this client too, so routing and DNS agree.
		cfg["dns"] = map[string]any{
			"queryStrategy": "UseIP",
			"servers": []any{
				map[string]any{
					"address":     "223.5.5.5",
					"domains":     []string{"geosite:cn"},
					"expectedIPs": []string{"geoip:cn"},
				},
				"8.8.8.8",
			},
		}
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
	if opts.Rules && !opts.Direct {
		// Rule mode is the fixed v2ray preset (geosite:cn +
		// geoip:cn); the profile's own rules are not translated.
		result.RulesApplied = 2
	}
	for _, p := range cfg.Proxies {
		nodeCfg, err := buildConfig(p, opts)
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
