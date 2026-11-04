package xraytranslate

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// ShareLinkFor renders one node of a Clash YAML profile as the
// conventional share URI for its protocol - the inverse of
// ParseShareLinks, so a node can be handed to another client.
// Fields only FlBox models (the cert pin) ride along as the
// de-facto pinSHA256 parameter hysteria2 links already use.
func ShareLinkFor(yamlText, name string) (string, error) {
	var cfg clashConfig
	if err := yaml.Unmarshal([]byte(yamlText), &cfg); err != nil {
		return "", err
	}
	for _, p := range cfg.Proxies {
		if p.Name == name {
			return shareLink(p)
		}
	}
	return "", fmt.Errorf("node %q not found", name)
}

func shareLink(p clashProxy) (string, error) {
	hostport := net.JoinHostPort(p.Server, strconv.Itoa(p.Port))
	network := p.Network
	if network == "" {
		network = "tcp"
	}
	switch strings.ToLower(p.Type) {
	case "vless":
		q := url.Values{}
		q.Set("encryption", "none")
		if p.Flow != "" {
			q.Set("flow", p.Flow)
		}
		q.Set("type", network)
		switch {
		case p.RealityOpts.PublicKey != "":
			q.Set("security", "reality")
			if sni := sniOf(p); sni != "" {
				q.Set("sni", sni)
			}
			if p.ClientFingerprint != "" {
				q.Set("fp", p.ClientFingerprint)
			}
			q.Set("pbk", p.RealityOpts.PublicKey)
			if p.RealityOpts.ShortID != "" {
				q.Set("sid", p.RealityOpts.ShortID)
			}
		case p.TLS:
			q.Set("security", "tls")
			setTLSQuery(q, p)
		default:
			q.Set("security", "none")
		}
		setTransportQuery(q, p, network)
		return (&url.URL{
			Scheme:   "vless",
			User:     url.User(p.UUID),
			Host:     hostport,
			RawQuery: q.Encode(),
			Fragment: p.Name,
		}).String(), nil
	case "vmess":
		m := map[string]any{
			"v": "2", "ps": p.Name, "add": p.Server,
			"port": strconv.Itoa(p.Port), "id": p.UUID,
			"aid": strconv.Itoa(p.AlterId), "scy": "auto",
			"net": network, "type": "none",
		}
		if network == "ws" {
			if p.WSOpts.Path != "" {
				m["path"] = p.WSOpts.Path
			}
			if h := p.WSOpts.Headers["Host"]; h != "" {
				m["host"] = h
			}
		}
		if p.TLS {
			m["tls"] = "tls"
			if sni := sniOf(p); sni != "" {
				m["sni"] = sni
			}
			if len(p.ALPN) > 0 {
				m["alpn"] = strings.Join(p.ALPN, ",")
			}
			if p.ClientFingerprint != "" {
				m["fp"] = p.ClientFingerprint
			}
		}
		raw, err := json.Marshal(m)
		if err != nil {
			return "", err
		}
		return "vmess://" + base64.StdEncoding.EncodeToString(raw), nil
	case "trojan":
		q := url.Values{}
		if sni := sniOf(p); sni != "" {
			q.Set("sni", sni)
		}
		if network != "tcp" {
			q.Set("type", network)
		}
		if len(p.ALPN) > 0 {
			q.Set("alpn", strings.Join(p.ALPN, ","))
		}
		if p.ClientFingerprint != "" {
			q.Set("fp", p.ClientFingerprint)
		}
		setTransportQuery(q, p, network)
		return (&url.URL{
			Scheme:   "trojan",
			User:     url.User(p.Password),
			Host:     hostport,
			RawQuery: q.Encode(),
			Fragment: p.Name,
		}).String(), nil
	case "ss", "shadowsocks":
		userinfo := base64.RawURLEncoding.EncodeToString(
			[]byte(p.Cipher + ":" + p.Password))
		return "ss://" + userinfo + "@" + hostport +
			"#" + url.QueryEscape(p.Name), nil
	case "hysteria2", "hy2":
		auth := p.Password
		if auth == "" {
			auth = p.Auth
		}
		q := url.Values{}
		if sni := sniOf(p); sni != "" {
			q.Set("sni", sni)
		}
		if p.Obfs != "" {
			q.Set("obfs", p.Obfs)
		}
		if p.ObfsPassword != "" {
			q.Set("obfs-password", p.ObfsPassword)
		}
		if p.Ports != "" {
			q.Set("mport", p.Ports)
		}
		if p.SkipCertVerify {
			q.Set("insecure", "1")
		}
		if p.PinnedCert != "" {
			q.Set("pinSHA256", p.PinnedCert)
		}
		if len(p.ALPN) > 0 {
			q.Set("alpn", strings.Join(p.ALPN, ","))
		}
		if up := bandwidthString(p.Up); up != "" {
			q.Set("up", up)
		}
		if down := bandwidthString(p.Down); down != "" {
			q.Set("down", down)
		}
		return (&url.URL{
			Scheme:   "hysteria2",
			User:     url.User(auth),
			Host:     hostport,
			RawQuery: q.Encode(),
			Fragment: p.Name,
		}).String(), nil
	case "wireguard":
		q := url.Values{}
		if p.PublicKey != "" {
			q.Set("publickey", p.PublicKey)
		}
		if p.PreSharedKey != "" {
			q.Set("presharedkey", p.PreSharedKey)
		}
		addrs := []string{}
		if p.IP != "" {
			addrs = append(addrs, p.IP)
		}
		if p.IPv6 != "" {
			addrs = append(addrs, p.IPv6)
		}
		if len(addrs) > 0 {
			q.Set("address", strings.Join(addrs, ","))
		}
		if p.MTU > 0 {
			q.Set("mtu", strconv.Itoa(p.MTU))
		}
		if len(p.Reserved) == 3 {
			parts := make([]string, 3)
			for i, n := range p.Reserved {
				parts[i] = strconv.Itoa(n)
			}
			q.Set("reserved", strings.Join(parts, ","))
		}
		return (&url.URL{
			Scheme:   "wireguard",
			User:     url.User(p.PrivateKey),
			Host:     hostport,
			RawQuery: q.Encode(),
			Fragment: p.Name,
		}).String(), nil
	}
	return "", fmt.Errorf("unsupported node type %q", p.Type)
}

func setTLSQuery(q url.Values, p clashProxy) {
	if sni := sniOf(p); sni != "" {
		q.Set("sni", sni)
	}
	if p.ClientFingerprint != "" {
		q.Set("fp", p.ClientFingerprint)
	}
	if len(p.ALPN) > 0 {
		q.Set("alpn", strings.Join(p.ALPN, ","))
	}
}

func setTransportQuery(q url.Values, p clashProxy, network string) {
	switch network {
	case "ws":
		if p.WSOpts.Path != "" {
			q.Set("path", p.WSOpts.Path)
		}
		if h := p.WSOpts.Headers["Host"]; h != "" {
			q.Set("host", h)
		}
	case "grpc":
		if p.GRPCOpts.ServiceName != "" {
			q.Set("serviceName", p.GRPCOpts.ServiceName)
		}
	}
}
