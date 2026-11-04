package xraytranslate

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

// Share-link import: vless/vmess/trojan/ss/hysteria2/wireguard
// URIs (one per line, or a base64 blob of them) become node
// entries in the same JSON shape the node editor produces, so a
// parsed link flows through UpsertNode like a hand-typed node.

var linkSchemes = []string{
	"vless://", "vmess://", "trojan://", "ss://",
	"hysteria2://", "hy2://", "wireguard://", "wg://",
}

func looksLikeLink(line string) bool {
	lower := strings.ToLower(line)
	for _, s := range linkSchemes {
		if strings.HasPrefix(lower, s) {
			return true
		}
	}
	return false
}

func decodeBase64Blob(s string) (string, error) {
	s = strings.Map(func(r rune) rune {
		if r == ' ' || r == '\n' || r == '\r' || r == '\t' {
			return -1
		}
		return r
	}, s)
	for _, enc := range []*base64.Encoding{
		base64.StdEncoding, base64.URLEncoding,
		base64.RawStdEncoding, base64.RawURLEncoding,
	} {
		if out, err := enc.DecodeString(s); err == nil {
			return string(out), nil
		}
	}
	return "", fmt.Errorf("not valid base64")
}

// ParseShareLinks parses one or more share links (or a base64
// subscription blob of them) into editor-shaped node entries.
// Returns {"entries": [...], "skipped": n}; it errors only when
// nothing at all could be parsed.
func ParseShareLinks(text string) (string, error) {
	lines := []string{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if looksLikeLink(line) {
			lines = append(lines, line)
		}
	}
	if len(lines) == 0 {
		decoded, err := decodeBase64Blob(text)
		if err != nil {
			return "", fmt.Errorf("no share links found")
		}
		for _, line := range strings.Split(decoded, "\n") {
			line = strings.TrimSpace(line)
			if looksLikeLink(line) {
				lines = append(lines, line)
			}
		}
	}
	if len(lines) == 0 {
		return "", fmt.Errorf("no share links found")
	}
	entries := []map[string]any{}
	skipped := 0
	var firstErr error
	for _, line := range lines {
		entry, err := parseShareLink(line)
		if err != nil {
			skipped++
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		entries = append(entries, entry)
	}
	if len(entries) == 0 {
		return "", fmt.Errorf("no parseable links: %v", firstErr)
	}
	out, err := json.Marshal(map[string]any{
		"entries": entries,
		"skipped": skipped,
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func parseShareLink(link string) (map[string]any, error) {
	lower := strings.ToLower(link)
	switch {
	case strings.HasPrefix(lower, "vmess://"):
		return parseVMess(link)
	case strings.HasPrefix(lower, "ss://"):
		return parseSS(link)
	}
	u, err := url.Parse(link)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()
	port, _ := strconv.Atoi(u.Port())
	if host == "" || port <= 0 {
		return nil, fmt.Errorf("link has no host:port")
	}
	name := u.Fragment
	if name == "" {
		name = u.Host
	}
	q := u.Query()
	entry := map[string]any{
		"name":   name,
		"server": host,
		"port":   port,
	}
	network := q.Get("type")
	if network == "" || network == "raw" || network == "tcp" {
		network = "tcp"
	}
	setNetwork := func() {
		if network != "tcp" {
			entry["network"] = network
		}
	}
	setTLS := func(sni string) {
		entry["tls"] = true
		if sni != "" {
			entry["servername"] = sni
		}
		if fp := q.Get("fp"); fp != "" {
			entry["client-fingerprint"] = fp
		}
		if alpn := q.Get("alpn"); alpn != "" {
			entry["alpn"] = strings.Split(alpn, ",")
		}
		if q.Get("allowInsecure") == "1" || q.Get("insecure") == "1" {
			entry["skip-cert-verify"] = true
		}
	}
	setWS := func() {
		ws := map[string]any{}
		if p := q.Get("path"); p != "" {
			ws["path"] = p
		}
		if h := q.Get("host"); h != "" {
			ws["headers"] = map[string]any{"Host": h}
		}
		if len(ws) > 0 {
			entry["ws-opts"] = ws
		}
	}

	switch strings.ToLower(u.Scheme) {
	case "vless":
		entry["type"] = "vless"
		entry["uuid"] = u.User.Username()
		if f := q.Get("flow"); f != "" {
			entry["flow"] = f
		}
		setNetwork()
		switch strings.ToLower(q.Get("security")) {
		case "reality":
			entry["tls"] = true
			opts := map[string]any{"public-key": q.Get("pbk")}
			if sid := q.Get("sid"); sid != "" {
				opts["short-id"] = sid
			}
			entry["reality-opts"] = opts
			if sni := q.Get("sni"); sni != "" {
				entry["servername"] = sni
			}
			if fp := q.Get("fp"); fp != "" {
				entry["client-fingerprint"] = fp
			}
		case "tls":
			setTLS(q.Get("sni"))
		}
		if network == "ws" {
			setWS()
		}
		if network == "grpc" {
			if sn := q.Get("serviceName"); sn != "" {
				entry["grpc-opts"] = map[string]any{"grpc-service-name": sn}
			}
		}
	case "trojan":
		entry["type"] = "trojan"
		entry["password"] = u.User.Username()
		setNetwork()
		setTLS(q.Get("sni"))
		if network == "ws" {
			setWS()
		}
	case "hysteria2", "hy2":
		entry["type"] = "hysteria2"
		auth := u.User.Username()
		if pw, ok := u.User.Password(); ok && pw != "" {
			auth = pw
		}
		entry["password"] = auth
		if sni := q.Get("sni"); sni != "" {
			entry["sni"] = sni
		}
		if q.Get("insecure") == "1" || q.Get("allowInsecure") == "1" {
			entry["skip-cert-verify"] = true
		}
		if obfs := q.Get("obfs"); obfs != "" {
			entry["obfs"] = obfs
			if op := q.Get("obfs-password"); op != "" {
				entry["obfs-password"] = op
			}
		}
		if up := q.Get("up"); up != "" {
			entry["up"] = bandwidthString(anyString(up))
		}
		if down := q.Get("down"); down != "" {
			entry["down"] = bandwidthString(anyString(down))
		}
		if pin := q.Get("pinSHA256"); pin != "" {
			entry["pinned-cert-sha256"] = pin
		}
		if mport := q.Get("mport"); mport != "" {
			entry["ports"] = mport
		}
		if alpn := q.Get("alpn"); alpn != "" {
			entry["alpn"] = strings.Split(alpn, ",")
		}
	case "wireguard", "wg":
		entry["type"] = "wireguard"
		entry["private-key"] = u.User.Username()
		if pk := q.Get("publickey"); pk != "" {
			entry["public-key"] = pk
		}
		if psk := q.Get("presharedkey"); psk != "" {
			entry["pre-shared-key"] = psk
		}
		for _, addr := range strings.Split(q.Get("address"), ",") {
			addr = strings.TrimSpace(addr)
			if addr == "" {
				continue
			}
			if strings.Contains(addr, ":") {
				entry["ipv6"] = addr
			} else {
				entry["ip"] = addr
			}
		}
		if mtu := q.Get("mtu"); mtu != "" {
			if n, err := strconv.Atoi(mtu); err == nil {
				entry["mtu"] = n
			}
		}
		if r := q.Get("reserved"); r != "" {
			parts := strings.Split(r, ",")
			nums := []int{}
			ok := len(parts) == 3
			for _, p := range parts {
				n, err := strconv.Atoi(strings.TrimSpace(p))
				if err != nil {
					ok = false
					break
				}
				nums = append(nums, n)
			}
			if ok {
				entry["reserved"] = nums
			}
		}
	default:
		return nil, fmt.Errorf("unsupported scheme %q", u.Scheme)
	}
	return entry, nil
}

// anyString lets bandwidthString treat a link's up/down query
// value like a Clash field: a bare number stays a number.
func anyString(s string) any {
	if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		return n
	}
	return s
}

func parseVMess(link string) (map[string]any, error) {
	body := strings.TrimSpace(link[len("vmess://"):])
	if i := strings.Index(body, "#"); i >= 0 {
		body = body[:i]
	}
	if i := strings.Index(body, "?"); i >= 0 {
		body = body[:i]
	}
	decoded, err := decodeBase64Blob(body)
	if err != nil {
		return nil, fmt.Errorf("vmess: %v", err)
	}
	var j map[string]any
	if err := json.Unmarshal([]byte(decoded), &j); err != nil {
		return nil, fmt.Errorf("vmess json: %v", err)
	}
	str := func(k string) string {
		switch v := j[k].(type) {
		case string:
			return v
		case float64:
			return strconv.FormatFloat(v, 'f', -1, 64)
		}
		return ""
	}
	port, _ := strconv.Atoi(str("port"))
	name := str("ps")
	if name == "" {
		name = str("add")
	}
	entry := map[string]any{
		"name":   name,
		"type":   "vmess",
		"server": str("add"),
		"port":   port,
		"uuid":   str("id"),
	}
	if aid, err := strconv.Atoi(str("aid")); err == nil && aid != 0 {
		entry["alterId"] = aid
	}
	if scy := str("scy"); scy != "" {
		entry["cipher"] = scy
	}
	network := str("net")
	if network != "" && network != "tcp" {
		entry["network"] = network
	}
	if str("tls") == "tls" {
		entry["tls"] = true
	}
	if sni := str("sni"); sni != "" {
		entry["servername"] = sni
	}
	if fp := str("fp"); fp != "" {
		entry["client-fingerprint"] = fp
	}
	if alpn := str("alpn"); alpn != "" {
		entry["alpn"] = strings.Split(alpn, ",")
	}
	if network == "ws" {
		ws := map[string]any{}
		if p := str("path"); p != "" {
			ws["path"] = p
		}
		if h := str("host"); h != "" {
			ws["headers"] = map[string]any{"Host": h}
		}
		if len(ws) > 0 {
			entry["ws-opts"] = ws
		}
	}
	if network == "grpc" {
		if p := str("path"); p != "" {
			entry["grpc-opts"] = map[string]any{"grpc-service-name": p}
		}
	}
	return entry, nil
}

func parseSS(link string) (map[string]any, error) {
	rest := link[len("ss://"):]
	name := ""
	if i := strings.Index(rest, "#"); i >= 0 {
		if frag, err := url.PathUnescape(rest[i+1:]); err == nil {
			name = frag
		}
		rest = rest[:i]
	}
	if i := strings.Index(rest, "?"); i >= 0 {
		rest = rest[:i]
	}
	var method, password, hostport string
	if strings.Contains(rest, "@") {
		at := strings.LastIndex(rest, "@")
		userinfo, hp := rest[:at], rest[at+1:]
		hostport = hp
		if strings.Contains(userinfo, ":") {
			parts := strings.SplitN(userinfo, ":", 2)
			method = parts[0]
			if pw, err := url.PathUnescape(parts[1]); err == nil {
				password = pw
			} else {
				password = parts[1]
			}
		} else {
			decoded, err := decodeBase64Blob(userinfo)
			if err != nil {
				return nil, fmt.Errorf("ss userinfo: %v", err)
			}
			parts := strings.SplitN(decoded, ":", 2)
			if len(parts) != 2 {
				return nil, fmt.Errorf("ss userinfo malformed")
			}
			method, password = parts[0], parts[1]
		}
	} else {
		// Legacy whole-URI base64: method:password@host:port.
		decoded, err := decodeBase64Blob(rest)
		if err != nil {
			return nil, fmt.Errorf("ss: %v", err)
		}
		at := strings.LastIndex(decoded, "@")
		if at < 0 {
			return nil, fmt.Errorf("ss legacy malformed")
		}
		parts := strings.SplitN(decoded[:at], ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("ss legacy malformed")
		}
		method, password = parts[0], parts[1]
		hostport = decoded[at+1:]
	}
	i := strings.LastIndex(hostport, ":")
	if i < 0 {
		return nil, fmt.Errorf("ss has no port")
	}
	host := hostport[:i]
	port, err := strconv.Atoi(hostport[i+1:])
	if err != nil {
		return nil, fmt.Errorf("ss port: %v", err)
	}
	if name == "" {
		name = hostport
	}
	return map[string]any{
		"name":     name,
		"type":     "ss",
		"server":   strings.Trim(host, "[]"),
		"port":     port,
		"cipher":   method,
		"password": password,
	}, nil
}
