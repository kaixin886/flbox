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
func FlboxXrayTranslate(clashYAML *C.char) *C.char {
	out, err := xrayTranslate(C.GoString(clashYAML))
	if err != nil {
		recordErr(err)
		return nil
	}
	return C.CString(out)
}

//export FlboxXrayStart
func FlboxXrayStart(configJSON *C.char) *C.char {
	return recordErr(xrayStart(C.GoString(configJSON)))
}

//export FlboxXrayStop
func FlboxXrayStop() *C.char {
	return recordErr(xrayStop())
}

//export FlboxFree
func FlboxFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

func main() {}
