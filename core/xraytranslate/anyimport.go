package xraytranslate

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// ConvertImport sniffs an imported file's format and normalises
// everything into a Clash YAML profile the translator eats:
//
//   - Clash YAML       — passed through untouched.
//   - share-link lists — plain lines, or a base64 blob of them.
//   - Xray JSON        — outbounds with a "protocol" field.
//   - sing-box JSON    — outbounds/endpoints with a "type" field.
//
// Only node-bearing entries are converted; selectors, direct /
// block entries, inbounds and routing are dropped. Returns the
// YAML plus a short kind tag for the UI's toast.
func ConvertImport(text string) (string, string, error) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return "", "", fmt.Errorf("empty file")
	}
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		entries, kind, err := entriesFromJSON([]byte(trimmed))
		if err != nil {
			return "", "", err
		}
		yamlText, err := entriesToYAML(entries)
		if err != nil {
			return "", "", err
		}
		return yamlText, kind, nil
	}
	if _, err := ParseShareLinks(text); err == nil {
		parsed, _ := ParseShareLinks(text)
		var res struct {
			Entries []map[string]any `json:"entries"`
		}
		if err := json.Unmarshal([]byte(parsed), &res); err != nil {
			return "", "", err
		}
		yamlText, err := entriesToYAML(res.Entries)
		if err != nil {
			return "", "", err
		}
		return yamlText, "links", nil
	}
	return text, "yaml", nil
}

func entriesToYAML(entries []map[string]any) (string, error) {
	yamlText := ""
	for _, entry := range entries {
		entryJSON, err := json.Marshal(entry)
		if err != nil {
			return "", err
		}
		out, err := UpsertNode([]byte(yamlText), string(entryJSON), "")
		if err != nil {
			return "", err
		}
		yamlText = out
	}
	if yamlText == "" {
		return "", fmt.Errorf("no convertible nodes found")
	}
	return yamlText, nil
}

// --- generic JSON helpers (fields arrive with loose typing) ---

func jStr(m map[string]any, key string) string {
	switch v := m[key].(type) {
	case string:
		return v
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	case bool:
		if v {
			return "true"
		}
		return "false"
	}
	return ""
}

func jInt(m map[string]any, key string) int {
	switch v := m[key].(type) {
	case float64:
		return int(v)
	case string:
		n, _ := strconv.Atoi(v)
		return n
	}
	return 0
}

func jBool(m map[string]any, key string) bool {
	b, _ := m[key].(bool)
	return b
}

func jMap(m map[string]any, key string) map[string]any {
	sub, _ := m[key].(map[string]any)
	return sub
}

func jList(m map[string]any, key string) []any {
	list, _ := m[key].([]any)
	return list
}

func jStrList(m map[string]any, key string) []string {
	out := []string{}
	for _, v := range jList(m, key) {
		if s, ok := v.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func entriesFromJSON(data []byte) ([]map[string]any, string, error) {
	var root map[string]any
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, "", fmt.Errorf("json: %v", err)
	}
	// A bare outbound object (no wrapping config).
	if _, hasProto := root["protocol"]; hasProto {
		if e := entryFromXrayOutbound(root); e != nil {
			return []map[string]any{e}, "xray-json", nil
		}
		return nil, "", fmt.Errorf("unsupported outbound protocol")
	}
	if _, hasType := root["type"]; hasType {
		if e, ok := entryFromSingboxOutbound(root); ok {
			return []map[string]any{e}, "singbox-json", nil
		}
		return nil, "", fmt.Errorf("unsupported outbound type")
	}
	outbounds := jList(root, "outbounds")
	if len(outbounds) == 0 {
		return nil, "", fmt.Errorf("json has no outbounds")
	}
	// Xray or sing-box? The first entry decides.
	first, _ := outbounds[0].(map[string]any)
	entries := []map[string]any{}
	if _, isXray := first["protocol"]; isXray {
		for _, raw := range outbounds {
			ob, _ := raw.(map[string]any)
			if e := entryFromXrayOutbound(ob); e != nil {
				entries = append(entries, e)
			}
		}
		if len(entries) == 0 {
			return nil, "", fmt.Errorf("no convertible xray outbounds")
		}
		return entries, "xray-json", nil
	}
	for _, raw := range outbounds {
		ob, _ := raw.(map[string]any)
		if e, ok := entryFromSingboxOutbound(ob); ok {
			entries = append(entries, e)
		}
	}
	for _, raw := range jList(root, "endpoints") {
		ep, _ := raw.(map[string]any)
		if e, ok := entryFromSingboxOutbound(ep); ok {
			entries = append(entries, e)
		}
	}
	if len(entries) == 0 {
		return nil, "", fmt.Errorf("no convertible sing-box outbounds")
	}
	return entries, "singbox-json", nil
}

// --- sing-box ---

func entryFromSingboxOutbound(ob map[string]any) (map[string]any, bool) {
	if ob == nil {
		return nil, false
	}
	typ := jStr(ob, "type")
	name := jStr(ob, "tag")
	if name == "" {
		name = typ
	}
	entry := map[string]any{"name": name}
	tls := jMap(ob, "tls")
	transport := jMap(ob, "transport")
	applyTLS := func(sniKey string) {
		if tls == nil || !jBool(tls, "enabled") {
			return
		}
		entry["tls"] = true
		if sni := jStr(tls, "server_name"); sni != "" {
			entry[sniKey] = sni
		}
		if jBool(tls, "insecure") {
			entry["skip-cert-verify"] = true
		}
		if alpn := jStrList(tls, "alpn"); len(alpn) > 0 {
			entry["alpn"] = alpn
		}
		if utls := jMap(tls, "utls"); utls != nil {
			if fp := jStr(utls, "fingerprint"); fp != "" {
				entry["client-fingerprint"] = fp
			}
		}
		if reality := jMap(tls, "reality"); reality != nil && jBool(reality, "enabled") {
			opts := map[string]any{"public-key": jStr(reality, "public_key")}
			if sid := jStr(reality, "short_id"); sid != "" {
				opts["short-id"] = sid
			}
			entry["reality-opts"] = opts
		}
	}
	applyTransport := func() {
		switch jStr(transport, "type") {
		case "ws":
			entry["network"] = "ws"
			ws := map[string]any{}
			if p := jStr(transport, "path"); p != "" {
				ws["path"] = p
			}
			if headers := jMap(transport, "headers"); headers != nil {
				if host := jStr(headers, "Host"); host != "" {
					ws["headers"] = map[string]any{"Host": host}
				}
			}
			if len(ws) > 0 {
				entry["ws-opts"] = ws
			}
		case "grpc":
			entry["network"] = "grpc"
			if sn := jStr(transport, "service_name"); sn != "" {
				entry["grpc-opts"] = map[string]any{"grpc-service-name": sn}
			}
		}
	}
	server := func() {
		entry["server"] = jStr(ob, "server")
		entry["port"] = jInt(ob, "server_port")
	}

	switch typ {
	case "vless":
		entry["type"] = "vless"
		server()
		entry["uuid"] = jStr(ob, "uuid")
		if f := jStr(ob, "flow"); f != "" {
			entry["flow"] = f
		}
		applyTLS("servername")
		applyTransport()
	case "vmess":
		entry["type"] = "vmess"
		server()
		entry["uuid"] = jStr(ob, "uuid")
		if aid := jInt(ob, "alter_id"); aid != 0 {
			entry["alterId"] = aid
		}
		if sec := jStr(ob, "security"); sec != "" {
			entry["cipher"] = sec
		}
		applyTLS("servername")
		applyTransport()
	case "trojan":
		entry["type"] = "trojan"
		server()
		entry["password"] = jStr(ob, "password")
		applyTLS("servername")
		applyTransport()
	case "shadowsocks":
		entry["type"] = "ss"
		server()
		entry["cipher"] = jStr(ob, "method")
		entry["password"] = jStr(ob, "password")
	case "hysteria2":
		entry["type"] = "hysteria2"
		server()
		entry["password"] = jStr(ob, "password")
		if obfs := jMap(ob, "obfs"); obfs != nil {
			if t := jStr(obfs, "type"); t != "" {
				entry["obfs"] = t
				if pw := jStr(obfs, "password"); pw != "" {
					entry["obfs-password"] = pw
				}
			}
		}
		if up := jInt(ob, "up_mbps"); up != 0 {
			entry["up"] = up
		}
		if down := jInt(ob, "down_mbps"); down != 0 {
			entry["down"] = down
		}
		if tls != nil {
			if sni := jStr(tls, "server_name"); sni != "" {
				entry["sni"] = sni
			}
			if jBool(tls, "insecure") {
				entry["skip-cert-verify"] = true
			}
			if alpn := jStrList(tls, "alpn"); len(alpn) > 0 {
				entry["alpn"] = alpn
			}
		}
	case "wireguard":
		entry["type"] = "wireguard"
		entry["private-key"] = jStr(ob, "private_key")
		for _, addr := range jStrList(ob, "address") {
			if strings.Contains(addr, ":") {
				entry["ipv6"] = addr
			} else {
				entry["ip"] = addr
			}
		}
		if mtu := jInt(ob, "mtu"); mtu != 0 {
			entry["mtu"] = mtu
		}
		peers := jList(ob, "peers")
		if len(peers) == 0 {
			return nil, false
		}
		peer, _ := peers[0].(map[string]any)
		entry["server"] = jStr(peer, "address")
		entry["port"] = jInt(peer, "port")
		entry["public-key"] = jStr(peer, "public_key")
		if psk := jStr(peer, "pre_shared_key"); psk != "" {
			entry["pre-shared-key"] = psk
		}
		if allowed := jStrList(peer, "allowed_ips"); len(allowed) > 0 {
			entry["allowed-ips"] = allowed
		}
		if reserved := jList(peer, "reserved"); len(reserved) == 3 {
			nums := []int{}
			for _, v := range reserved {
				if f, ok := v.(float64); ok {
					nums = append(nums, int(f))
				}
			}
			if len(nums) == 3 {
				entry["reserved"] = nums
			}
		}
	default:
		return nil, false
	}
	return entry, true
}

// --- Xray JSON ---

func entryFromXrayOutbound(ob map[string]any) map[string]any {
	if ob == nil {
		return nil
	}
	proto := strings.ToLower(jStr(ob, "protocol"))
	name := jStr(ob, "tag")
	settings := jMap(ob, "settings")
	stream := jMap(ob, "streamSettings")
	entry := map[string]any{"name": name}

	firstOf := func(key string) map[string]any {
		list := jList(settings, key)
		if len(list) == 0 {
			return nil
		}
		m, _ := list[0].(map[string]any)
		return m
	}
	serverOf := func(key string) (map[string]any, bool) {
		s := firstOf(key)
		if s == nil {
			return nil, false
		}
		entry["server"] = jStr(s, "address")
		entry["port"] = jInt(s, "port")
		return s, true
	}

	// Transport/security first: hy2 needs them, the rest share them.
	network := strings.ToLower(jStr(stream, "network"))
	security := strings.ToLower(jStr(stream, "security"))
	applyStream := func() {
		if network == "ws" || network == "websocket" {
			entry["network"] = "ws"
			ws := jMap(stream, "wsSettings")
			opts := map[string]any{}
			if p := jStr(ws, "path"); p != "" {
				opts["path"] = p
			}
			if headers := jMap(ws, "headers"); headers != nil {
				if host := jStr(headers, "Host"); host != "" {
					opts["headers"] = map[string]any{"Host": host}
				}
			}
			if len(opts) > 0 {
				entry["ws-opts"] = opts
			}
		}
		if network == "grpc" {
			entry["network"] = "grpc"
			gs := jMap(stream, "grpcSettings")
			if sn := jStr(gs, "serviceName"); sn != "" {
				entry["grpc-opts"] = map[string]any{"grpc-service-name": sn}
			}
		}
		switch security {
		case "reality":
			entry["tls"] = true
			rs := jMap(stream, "realitySettings")
			if sni := jStr(rs, "serverName"); sni != "" {
				entry["servername"] = sni
			}
			if fp := jStr(rs, "fingerprint"); fp != "" {
				entry["client-fingerprint"] = fp
			}
			opts := map[string]any{"public-key": jStr(rs, "publicKey")}
			if sid := jStr(rs, "shortId"); sid != "" {
				opts["short-id"] = sid
			}
			entry["reality-opts"] = opts
		case "tls":
			entry["tls"] = true
			ts := jMap(stream, "tlsSettings")
			if sni := jStr(ts, "serverName"); sni != "" {
				entry["servername"] = sni
			}
			if fp := jStr(ts, "fingerprint"); fp != "" {
				entry["client-fingerprint"] = fp
			}
			if alpn := jStrList(ts, "alpn"); len(alpn) > 0 {
				entry["alpn"] = alpn
			}
			if jBool(ts, "allowInsecure") {
				entry["skip-cert-verify"] = true
			}
			if pin := jStr(ts, "pinnedPeerCertSha256"); pin != "" {
				entry["pinned-cert-sha256"] = pin
			}
		}
	}

	switch proto {
	case "vless", "vmess":
		vnext, ok := serverOf("vnext")
		if !ok {
			return nil
		}
		users := jList(vnext, "users")
		if len(users) == 0 {
			return nil
		}
		user, _ := users[0].(map[string]any)
		entry["type"] = proto
		entry["uuid"] = jStr(user, "id")
		if proto == "vless" {
			if f := jStr(user, "flow"); f != "" {
				entry["flow"] = f
			}
		} else {
			if aid := jInt(user, "alterId"); aid != 0 {
				entry["alterId"] = aid
			}
			if sec := jStr(user, "security"); sec != "" {
				entry["cipher"] = sec
			}
		}
		applyStream()
	case "trojan":
		s, ok := serverOf("servers")
		if !ok {
			return nil
		}
		entry["type"] = "trojan"
		entry["password"] = jStr(s, "password")
		applyStream()
	case "shadowsocks":
		s, ok := serverOf("servers")
		if !ok {
			return nil
		}
		entry["type"] = "ss"
		entry["cipher"] = jStr(s, "method")
		entry["password"] = jStr(s, "password")
	case "hysteria":
		entry["type"] = "hysteria2"
		entry["server"] = jStr(settings, "address")
		entry["port"] = jInt(settings, "port")
		hs := jMap(stream, "hysteriaSettings")
		entry["password"] = jStr(hs, "auth")
		ts := jMap(stream, "tlsSettings")
		if sni := jStr(ts, "serverName"); sni != "" {
			entry["sni"] = sni
		}
		if jBool(ts, "allowInsecure") {
			entry["skip-cert-verify"] = true
		}
		if pin := jStr(ts, "pinnedPeerCertSha256"); pin != "" {
			entry["pinned-cert-sha256"] = pin
		}
		if alpn := jStrList(ts, "alpn"); len(alpn) > 0 {
			entry["alpn"] = alpn
		}
		if fm := jMap(stream, "finalmask"); fm != nil {
			for _, raw := range jList(fm, "udp") {
				mask, _ := raw.(map[string]any)
				if jStr(mask, "type") == "salamander" {
					entry["obfs"] = "salamander"
					ms := jMap(mask, "settings")
					if pw := jStr(ms, "password"); pw != "" {
						entry["obfs-password"] = pw
					}
				}
			}
			if qp := jMap(fm, "quicParams"); qp != nil {
				if up := jStr(qp, "brutalUp"); up != "" {
					entry["up"] = up
				}
				if down := jStr(qp, "brutalDown"); down != "" {
					entry["down"] = down
				}
			}
		}
	case "wireguard":
		entry["type"] = "wireguard"
		entry["private-key"] = jStr(settings, "secretKey")
		for _, addr := range jStrList(settings, "address") {
			if strings.Contains(addr, ":") {
				entry["ipv6"] = addr
			} else {
				entry["ip"] = addr
			}
		}
		if mtu := jInt(settings, "mtu"); mtu != 0 {
			entry["mtu"] = mtu
		}
		peers := jList(settings, "peers")
		if len(peers) == 0 {
			return nil
		}
		peer, _ := peers[0].(map[string]any)
		endpoint := jStr(peer, "endpoint")
		if i := strings.LastIndex(endpoint, ":"); i > 0 {
			entry["server"] = strings.Trim(endpoint[:i], "[]")
			entry["port"], _ = strconv.Atoi(endpoint[i+1:])
		}
		entry["public-key"] = jStr(peer, "publicKey")
		if psk := jStr(peer, "preSharedKey"); psk != "" {
			entry["pre-shared-key"] = psk
		}
		if allowed := jStrList(peer, "allowedIPs"); len(allowed) > 0 {
			entry["allowed-ips"] = allowed
		}
		if r := jStr(settings, "reserved"); r != "" {
			if raw, err := base64.StdEncoding.DecodeString(r); err == nil && len(raw) == 3 {
				entry["reserved"] = []int{int(raw[0]), int(raw[1]), int(raw[2])}
			}
		}
	default:
		return nil
	}
	if name == "" {
		entry["name"] = fmt.Sprintf("%s-%v", entry["type"], entry["port"])
	}
	return entry
}
