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
	lastErrMu.Lock()
	lastErr = err.Error()
	lastErrMu.Unlock()
	return C.CString(err.Error())
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
func FlboxStart(configJSON *C.char) *C.char {
	return recordErr(startCore(C.GoString(configJSON)))
}

//export FlboxStop
func FlboxStop() *C.char {
	return recordErr(stopCore())
}

//export FlboxVpnForwardStart
func FlboxVpnForwardStart(tunFd C.int) *C.char {
	return recordErr(startVpnForward(int(tunFd)))
}

//export FlboxVpnForwardStop
func FlboxVpnForwardStop() *C.char {
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
func FlboxXrayTranslate(clashYAML, mode, logPath *C.char) *C.char {
	out, err := xrayTranslate(
		C.GoString(clashYAML),
		C.GoString(mode),
		C.GoString(logPath),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxXrayTranslateAll
func FlboxXrayTranslateAll(clashYAML, logPath *C.char) *C.char {
	out, err := xrayTranslateAll(
		C.GoString(clashYAML),
		C.GoString(logPath),
	)
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxXrayStart
func FlboxXrayStart(configJSON *C.char, tunFd C.int) *C.char {
	return recordErr(xrayStart(C.GoString(configJSON), int(tunFd)))
}

//export FlboxXrayStop
func FlboxXrayStop() *C.char {
	return recordErr(xrayStop())
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

//export FlboxFree
func FlboxFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

func main() {}
