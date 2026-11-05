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

	"flbox/core/xraytranslate"

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

//export FlboxSetup
func FlboxSetup(basePath, workingPath, tempPath *C.char) *C.char {
	return recordErr(setupCore(
		C.GoString(basePath),
		C.GoString(workingPath),
		C.GoString(tempPath),
	))
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

//export FlboxXrayMeasureAll
func FlboxXrayMeasureAll(configsJSON, url *C.char) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			noteErr(fmt.Errorf("core panic recovered: %v", r))
			out = C.CString("")
		}
	}()
	res, err := xrayMeasureAll(C.GoString(configsJSON), C.GoString(url))
	if err != nil {
		noteErr(err)
		return C.CString("")
	}
	return C.CString(res)
}

//export FlboxBridgeXrayConfig
func FlboxBridgeXrayConfig(clashYAML, selectedNode *C.char, ipv6 C.int, mode C.int, uidsJSON *C.char, routeMode C.int) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			noteErr(fmt.Errorf("core panic recovered: %v", r))
			out = nil
		}
	}()
	var uids []int
	if s := C.GoString(uidsJSON); s != "" {
		if err := json.Unmarshal([]byte(s), &uids); err != nil {
			noteErr(err)
			return nil
		}
	}
	cfg, err := bridgeXrayConfigs(
		C.GoString(clashYAML),
		C.GoString(selectedNode),
		ipv6 != 0,
		int(mode),
		uids,
		int(routeMode),
	)
	if err != nil {
		noteErr(err)
		return nil
	}
	return C.CString(cfg)
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
