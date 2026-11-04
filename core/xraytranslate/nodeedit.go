package xraytranslate

import (
	"regexp"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Node-level editing of a Clash profile, backing the app's node
// editor: the Dart form ships a node's fields as JSON, these
// helpers splice them into the profile's YAML through the yaml
// node tree, so the rest of the document (rules, other nodes,
// provider comments) survives untouched. The translator stays the
// only place that interprets the fields.

// keyOrder is the canonical field order for a written proxy entry:
// identity first, then credentials, then transport. Keys not listed
// here are appended alphabetically.
var keyOrder = []string{
	"name", "type", "server", "port",
	"uuid", "password", "cipher", "alterId", "flow",
	"network", "tls", "servername", "sni", "client-fingerprint",
	"skip-cert-verify", "alpn",
	"reality-opts", "ws-opts", "grpc-opts",
	"obfs", "obfs-password", "auth", "up", "down",
	"ports", "hop-interval",
	"pinned-cert-sha256",
	"private-key", "public-key", "pre-shared-key",
	"ip", "ipv6", "allowed-ips", "mtu", "reserved",
	"udp",
}

func loadDoc(yamlText []byte) (*yaml.Node, error) {
	if len(bytes.TrimSpace(yamlText)) == 0 {
		doc := &yaml.Node{Kind: yaml.DocumentNode}
		doc.Content = []*yaml.Node{{Kind: yaml.MappingNode, Tag: "!!map"}}
		return doc, nil
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(yamlText, &doc); err != nil {
		return nil, err
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) == 0 ||
		doc.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("profile is not a YAML mapping")
	}
	return &doc, nil
}

func dumpDoc(doc *yaml.Node) (string, error) {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(doc); err != nil {
		return "", err
	}
	if err := enc.Close(); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// proxiesSeq returns the proxies sequence node, creating the key
// (and the sequence) when the profile has none yet.
func proxiesSeq(doc *yaml.Node, create bool) *yaml.Node {
	root := doc.Content[0]
	for i := 0; i+1 < len(root.Content); i += 2 {
		if root.Content[i].Value == "proxies" {
			seq := root.Content[i+1]
			if seq.Kind != yaml.SequenceNode {
				return nil
			}
			return seq
		}
	}
	if !create {
		return nil
	}
	seq := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	root.Content = append(root.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "proxies"},
		seq)
	return seq
}

func entryName(entry *yaml.Node) string {
	if entry.Kind != yaml.MappingNode {
		return ""
	}
	for i := 0; i+1 < len(entry.Content); i += 2 {
		if entry.Content[i].Value == "name" {
			return entry.Content[i+1].Value
		}
	}
	return ""
}

// NodeDetail returns the named proxy's entry as a JSON object, or
// an error when the profile has no such node.
func NodeDetail(yamlText []byte, name string) (string, error) {
	doc, err := loadDoc(yamlText)
	if err != nil {
		return "", err
	}
	seq := proxiesSeq(doc, false)
	if seq == nil {
		return "", errors.New("profile has no proxies")
	}
	for _, entry := range seq.Content {
		if entryName(entry) == name {
			var asMap map[string]any
			if err := entry.Decode(&asMap); err != nil {
				return "", err
			}
			out, err := json.Marshal(asMap)
			if err != nil {
				return "", err
			}
			return string(out), nil
		}
	}
	return "", fmt.Errorf("node %q not found", name)
}

// yamlValue converts a decoded JSON value into a yaml node,
// keeping integral numbers as ints (ports must not come back as
// 443.0) and ordering mapping keys canonically.
func yamlValue(v any) *yaml.Node {
	switch t := v.(type) {
	case map[string]any:
		node := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.SliceStable(keys, func(i, j int) bool {
			oi, oj := orderOf(keys[i]), orderOf(keys[j])
			if oi != oj {
				return oi < oj
			}
			return keys[i] < keys[j]
		})
		for _, k := range keys {
			if t[k] == nil {
				continue
			}
			node.Content = append(node.Content,
				&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: k},
				yamlValue(t[k]))
		}
		return node
	case []any:
		node := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
		for _, e := range t {
			node.Content = append(node.Content, yamlValue(e))
		}
		return node
	case string:
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: t}
	case bool:
		if t {
			return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "true"}
		}
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"}
	case float64:
		if t == float64(int64(t)) {
			return &yaml.Node{
				Kind:  yaml.ScalarNode,
				Tag:   "!!int",
				Value: fmt.Sprintf("%d", int64(t)),
			}
		}
		return &yaml.Node{
			Kind:  yaml.ScalarNode,
			Tag:   "!!float",
			Value: fmt.Sprintf("%v", t),
		}
	case nil:
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!null", Value: "null"}
	}
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: fmt.Sprintf("%v", v)}
}

func orderOf(key string) int {
	for i, k := range keyOrder {
		if k == key {
			return i
		}
	}
	return len(keyOrder)
}

// UpsertNode splices a node entry (JSON object with typed values)
// into the profile: it replaces the entry named originalName when
// given, else an entry with the same name, else appends. Returns
// the rewritten profile.
func UpsertNode(yamlText []byte, entryJSON string, originalName string) (string, error) {
	var entry map[string]any
	if err := json.Unmarshal([]byte(entryJSON), &entry); err != nil {
		return "", err
	}
	name, _ := entry["name"].(string)
	if strings.TrimSpace(name) == "" {
		return "", errors.New("node entry has no name")
	}
	doc, err := loadDoc(yamlText)
	if err != nil {
		return "", err
	}
	seq := proxiesSeq(doc, true)
	if seq == nil {
		return "", errors.New("profile's proxies is not a list")
	}
	node := yamlValue(entry)
	target := originalName
	if target == "" {
		target = name
	}
	for i, e := range seq.Content {
		if entryName(e) == target {
			seq.Content[i] = node
			return dumpDoc(doc)
		}
	}
	seq.Content = append(seq.Content, node)
	return dumpDoc(doc)
}

// DeleteNode removes the named entry from the profile.
func DeleteNode(yamlText []byte, name string) (string, error) {
	doc, err := loadDoc(yamlText)
	if err != nil {
		return "", err
	}
	seq := proxiesSeq(doc, false)
	if seq == nil {
		return "", errors.New("profile has no proxies")
	}
	for i, e := range seq.Content {
		if entryName(e) == name {
			seq.Content = append(seq.Content[:i], seq.Content[i+1:]...)
			return dumpDoc(doc)
		}
	}
	return "", fmt.Errorf("node %q not found", name)
}

// FilterNodes applies keep/drop regular expressions to node
// names: an entry survives when it matches keep (when set) and
// does not match drop (when set). Subscription updates run it so a
// profile can pin the nodes it actually wants.
func FilterNodes(yamlText []byte, keep, drop string) (string, error) {
	var keepRe, dropRe *regexp.Regexp
	var err error
	if strings.TrimSpace(keep) != "" {
		if keepRe, err = regexp.Compile(keep); err != nil {
			return "", fmt.Errorf("keep regex: %w", err)
		}
	}
	if strings.TrimSpace(drop) != "" {
		if dropRe, err = regexp.Compile(drop); err != nil {
			return "", fmt.Errorf("drop regex: %w", err)
		}
	}
	if keepRe == nil && dropRe == nil {
		return string(yamlText), nil
	}
	doc, err := loadDoc(yamlText)
	if err != nil {
		return "", err
	}
	seq := proxiesSeq(doc, false)
	if seq == nil {
		return string(yamlText), nil
	}
	kept := seq.Content[:0]
	for _, e := range seq.Content {
		name := entryName(e)
		if keepRe != nil && !keepRe.MatchString(name) {
			continue
		}
		if dropRe != nil && dropRe.MatchString(name) {
			continue
		}
		kept = append(kept, e)
	}
	seq.Content = kept
	return dumpDoc(doc)
}
