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
	Nodes   []NodeInfo           `json:"nodes"`
	Skipped []SkippedNode        `json:"skipped"`
	Configs map[string]string    `json:"configs"`
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

func buildConfig(p clashProxy) (string, error) {
	outbound, err := nodeOutbound(p)
	if err != nil {
		return "", err
	}
	cfg := map[string]any{
		"log": map[string]any{"loglevel": "warning"},
		"inbounds": []any{
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
		},
		"outbounds": []any{
			outbound,
			map[string]any{"tag": "direct", "protocol": "freedom"},
			map[string]any{"tag": "block", "protocol": "blackhole"},
		},
		"routing": map[string]any{
			"domainStrategy": "AsIs",
			"rules": []any{
				map[string]any{
					"type":        "field",
					"ip":          privateCIDRs,
					"outboundTag": "direct",
				},
				map[string]any{
					"type":        "field",
					"inboundTag":  []string{"in"},
					"outboundTag": "proxy",
				},
			},
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
func Translate(clashYAML []byte) (*Result, error) {
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
	for _, p := range cfg.Proxies {
		nodeCfg, err := buildConfig(p)
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
