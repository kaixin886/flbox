// FlBox core: a c-shared library called from Dart through FFI.
// The API is deliberately tiny; every returned *C.char is heap-allocated
// and must be released by the caller through FlboxFree. A nil return from
// the int-like entry points means success, a non-nil return is an error
// message.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"sync"
	"unsafe"

	"flbox/core/sbtranslate"
	"flbox/core/xraytranslate"

	"github.com/sagernet/sing-box/experimental/libbox"
)

var (
	lastErrMu sync.Mutex
	lastErr   string
)

func recordErr(err error) *C.char {
	if err == nil {
		return nil
	}
	noteErr(err)
	return C.CString(err.Error())
}

// noteErr stores err as the last error without allocating a
// return string, for entry points whose return value carries
// data rather than the error itself.
func noteErr(err error) {
	if err == nil {
		return
	}
	lastErrMu.Lock()
	lastErr = err.Error()
	lastErrMu.Unlock()
}

func translateClash(clashYAML string) (string, error) {
	cfg, err := sbtranslate.ParseClash([]byte(clashYAML))
	if err != nil {
		return "", err
	}
	out, err := sbtranslate.Translate(cfg)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// Self-check: proves the translator is linked and functional before any
// real profile is involved. Uses a placeholder node only.
var selfCheckErr error

func init() {
	const placeholder = `
mixed-port: 7890
proxies:
  - name: placeholder
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: placeholder
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - placeholder
rules:
  - MATCH,PROXY
`
	_, selfCheckErr = translateClash(placeholder)
}

//export FlboxVersion
func FlboxVersion() *C.char {
	return C.CString("flbox-core 0.1.0 (sing-box " + libbox.Version() + ")")
}

//export FlboxSelfCheck
func FlboxSelfCheck() *C.char {
	return recordErr(selfCheckErr)
}

//export FlboxSetup
func FlboxSetup(basePath, workingPath, tempPath *C.char) *C.char {
	return recordErr(setupCore(
		C.GoString(basePath),
		C.GoString(workingPath),
		C.GoString(tempPath),
	))
}

//export FlboxTranslate
func FlboxTranslate(clashYAML *C.char) *C.char {
	out, err := translateClash(C.GoString(clashYAML))
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxStart
func FlboxStart(configJSON *C.char) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(startCore(C.GoString(configJSON)))
}

//export FlboxStop
func FlboxStop() (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(stopCore())
}

// Panic guard for the FFI boundary: an unrecovered Go panic in
// any of these entry points kills the whole app process (the
// user sees a flash-crash with no message). Recovering turns it
// into the ordinary error string Dart already handles, and the
// message lands in the log page instead.

//export FlboxVpnForwardStart
func FlboxVpnForwardStart(tunFd C.int, ipv6 C.int) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(startVpnForward(int(tunFd), int(ipv6) != 0))
}

//export FlboxVpnForwardStop
func FlboxVpnForwardStop() (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(stopVpnForward())
}

//export FlboxVpnForwardActive
func FlboxVpnForwardActive() C.int {
	if vpnForwardActive() {
		return 1
	}
	return 0
}

//export FlboxLastError
func FlboxLastError() *C.char {
	lastErrMu.Lock()
	defer lastErrMu.Unlock()
	if lastErr == "" {
		return nil
	}
	return C.CString(lastErr)
}

//export FlboxXrayVersion
func FlboxXrayVersion() *C.char {
	return C.CString("Xray " + xrayVersion())
}

//export FlboxXrayTranslate
func FlboxXrayTranslate(clashYAML, mode, logPath *C.char) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			recordErr(fmt.Errorf("core panic recovered: %v", r))
			out = nil
		}
	}()
	res, err := xrayTranslate(
		C.GoString(clashYAML),
		C.GoString(mode),
		C.GoString(logPath),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(res)
}

//export FlboxXrayTranslateAll
func FlboxXrayTranslateAll(clashYAML, logPath *C.char) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			recordErr(fmt.Errorf("core panic recovered: %v", r))
			out = nil
		}
	}()
	res, err := xrayTranslateAll(
		C.GoString(clashYAML),
		C.GoString(logPath),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(res)
}

//export FlboxXrayStart
func FlboxXrayStart(configJSON *C.char, tunFd C.int) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(xrayStart(C.GoString(configJSON), int(tunFd)))
}

//export FlboxXrayStop
func FlboxXrayStop() (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(xrayStop())
}

//export FlboxXrayTestStart
func FlboxXrayTestStart(configJSON *C.char, port C.int) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(xrayTestStart(C.GoString(configJSON), int(port)))
}

//export FlboxXrayTestStop
func FlboxXrayTestStop(port C.int) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = C.CString(fmt.Sprintf("core panic recovered: %v", r))
		}
	}()
	return recordErr(xrayTestStop(int(port)))
}

//export FlboxXrayMeasureDelay
func FlboxXrayMeasureDelay(configJSON, url *C.char) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			noteErr(fmt.Errorf("core panic recovered: %v", r))
			out = C.CString("-1")
		}
	}()
	ms, err := xrayMeasureDelay(C.GoString(configJSON), C.GoString(url))
	if err != nil {
		noteErr(err)
		return C.CString("-1")
	}
	return C.CString(fmt.Sprintf("%d", ms))
}

//export FlboxXrayStatus
func FlboxXrayStatus() *C.char {
	return C.CString(xrayStatus())
}

//export FlboxXrayTraffic
func FlboxXrayTraffic() *C.char {
	return C.CString(xrayTraffic())
}

//export FlboxNodeDetail
func FlboxNodeDetail(clashYAML, name *C.char) *C.char {
	out, err := xraytranslate.NodeDetail(
		[]byte(C.GoString(clashYAML)),
		C.GoString(name),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxNodeShare
func FlboxNodeShare(clashYAML, name *C.char) *C.char {
	out, err := xraytranslate.ShareLinkFor(
		C.GoString(clashYAML),
		C.GoString(name),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxNodeUpsert
func FlboxNodeUpsert(clashYAML, entryJSON, originalName *C.char) *C.char {
	out, err := xraytranslate.UpsertNode(
		[]byte(C.GoString(clashYAML)),
		C.GoString(entryJSON),
		C.GoString(originalName),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxNodeDelete
func FlboxNodeDelete(clashYAML, name *C.char) *C.char {
	out, err := xraytranslate.DeleteNode(
		[]byte(C.GoString(clashYAML)),
		C.GoString(name),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxFilterNodes
func FlboxFilterNodes(clashYAML, keep, drop *C.char) *C.char {
	out, err := xraytranslate.FilterNodes(
		[]byte(C.GoString(clashYAML)),
		C.GoString(keep),
		C.GoString(drop),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxParseShareLinks
func FlboxParseShareLinks(text *C.char) *C.char {
	out, err := xraytranslate.ParseShareLinks(C.GoString(text))
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxConvertImport
func FlboxConvertImport(text *C.char) *C.char {
	yamlText, kind, err := xraytranslate.ConvertImport(C.GoString(text))
	if err != nil {
		recordErr(err)
		return nil
	}
	out, err := json.Marshal(map[string]string{"yaml": yamlText, "kind": kind})
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(string(out))
}

//export FlboxFree
func FlboxFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

func main() {}
