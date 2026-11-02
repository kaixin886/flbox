// Package sbtranslate converts a Clash/Mihomo YAML profile (the format
// FlClash's Dart layer writes to config.yaml) into a sing-box JSON
// configuration. Stage-1 milestone A scope: vless / hysteria2 / shadowsocks /
// trojan proxies, select & url-test groups, the common rule types, one mixed
// inbound. Unknown proxy types are a hard error, never silently dropped
// (the netproxy URI lesson: dropping fields silently is how nodes die).
package sbtranslate

import (
	"fmt"

	"gopkg.in/yaml.v3"
)

// ClashConfig is the subset of the Clash YAML schema that stage 1 reads.
type ClashConfig struct {
	Port      int          `yaml:"port"`
	SocksPort int          `yaml:"socks-port"`
	MixedPort int          `yaml:"mixed-port"`
	Mode      string       `yaml:"mode"`
	DNS       *ClashDNS    `yaml:"dns"`
	Proxies   []ClashProxy `yaml:"proxies"`
	Groups    []ClashGroup `yaml:"proxy-groups"`
	Rules     []string     `yaml:"rules"`
}

type ClashDNS struct {
	Enable     bool     `yaml:"enable"`
	Nameserver []string `yaml:"nameserver"`
}

type ClashProxy struct {
	Name              string   `yaml:"name"`
	Type              string   `yaml:"type"`
	Server            string   `yaml:"server"`
	Port              int      `yaml:"port"`
	UUID              string   `yaml:"uuid"`
	Password          string   `yaml:"password"`
	Method            string   `yaml:"cipher"` // shadowsocks
	Flow              string   `yaml:"flow"`
	Network           string   `yaml:"network"`
	TLS               bool     `yaml:"tls"`
	ServerName        string   `yaml:"servername"`
	SNI               string   `yaml:"sni"`
	ClientFingerprint string   `yaml:"client-fingerprint"`
	SkipCertVerify    bool     `yaml:"skip-cert-verify"`
	PinSHA256         string   `yaml:"pinSHA256"`
	ALPN              []string `yaml:"alpn"`
	RealityOpts       *struct {
		PublicKey string `yaml:"public-key"`
		ShortID   string `yaml:"short-id"`
	} `yaml:"reality-opts"`
	// hysteria2 bandwidth hints, e.g. "100 Mbps"
	Up   string `yaml:"up"`
	Down string `yaml:"down"`
}

type ClashGroup struct {
	Name     string   `yaml:"name"`
	Type     string   `yaml:"type"` // select | url-test | fallback
	Proxies  []string `yaml:"proxies"`
	URL      string   `yaml:"url"`
	Interval int      `yaml:"interval"` // seconds
}

// ParseClash decodes Clash YAML bytes.
func ParseClash(data []byte) (*ClashConfig, error) {
	var cfg ClashConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse clash yaml: %w", err)
	}
	return &cfg, nil
}

func (p *ClashProxy) serverName() string {
	if p.ServerName != "" {
		return p.ServerName
	}
	return p.SNI
}
