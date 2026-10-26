// Command export builds libtvvpn, the C interface the Swift app links:
//
//	int  TVVPNStart(const char *confPath, char *errBuf, int errLen);
//	void TVVPNStop(int port);
//
// Start brings up the tunnel for a WireGuard .conf and returns the local SOCKS5
// port, or -1 with a message in errBuf. It blocks while the device comes up, so
// call it off the main thread. Build with swift/vpn/build.sh.
package main

/*
#include <stdlib.h>
#include <string.h>

static void tvvpn_seterr(char *buf, int n, const char *s) {
	if (buf == NULL || n <= 0) return;
	strncpy(buf, s, (size_t)n - 1);
	buf[n - 1] = 0;
}
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"

	"tvview/swift/vpn/tunnel"
)

var (
	mu      sync.Mutex
	started = map[int]*tunnel.Tunnel{}
)

func fail(buf *C.char, n C.int, msg string) C.int {
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.tvvpn_seterr(buf, n, cs)
	return -1
}

//export TVVPNStart
func TVVPNStart(confPath *C.char, errBuf *C.char, errLen C.int) (port C.int) {
	// A panic in wireguard-go must not take the app down with it.
	defer func() {
		if r := recover(); r != nil {
			port = fail(errBuf, errLen, fmt.Sprint("internal error: ", r))
		}
	}()

	t, err := tunnel.Start(C.GoString(confPath))
	if err != nil {
		return fail(errBuf, errLen, err.Error())
	}
	mu.Lock()
	started[t.Port] = t
	mu.Unlock()
	return C.int(t.Port)
}

//export TVVPNStop
func TVVPNStop(port C.int) {
	mu.Lock()
	t := started[int(port)]
	delete(started, int(port))
	mu.Unlock()
	if t != nil {
		t.Close()
	}
}

func main() {}
