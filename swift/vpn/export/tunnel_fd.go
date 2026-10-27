package main

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

// The iOS SDK ships no <sys/kern_control.h>; these are its definitions (and the
// numbers are the same ones WireGuard's own iOS code uses to find its tunnel).
struct tvvpn_ctl_info {
	uint32_t ctl_id;
	char ctl_name[96];
};
struct tvvpn_sockaddr_ctl {
	uint8_t sc_len;
	uint8_t sc_family;
	uint16_t ss_sysaddr;
	uint32_t sc_id;
	uint32_t sc_unit;
	uint32_t sc_reserved[5];
};
#define TVVPN_CTLIOCGINFO _IOWR('N', 3, struct tvvpn_ctl_info)
#define TVVPN_AF_SYSTEM 32

// The packet tunnel provider is handed its utun device as an already-open file
// descriptor, but not told which one. Find it: the socket whose peer is the utun
// kernel control.
static int tvvpn_find_utun_fd(void) {
	struct tvvpn_ctl_info info;
	memset(&info, 0, sizeof info);
	strncpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name) - 1);
	for (int fd = 0; fd <= 1024; fd++) {
		struct tvvpn_sockaddr_ctl addr;
		socklen_t len = sizeof addr;
		memset(&addr, 0, sizeof addr);
		if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0) continue;
		if (addr.sc_family != TVVPN_AF_SYSTEM) continue;
		if (info.ctl_id == 0 && ioctl(fd, TVVPN_CTLIOCGINFO, &info) != 0) continue;
		if (addr.sc_id == info.ctl_id) return fd;
	}
	return -1;
}

static void tvvpn_tunnel_seterr(char *buf, int n, const char *s) {
	if (buf == NULL || n <= 0) return;
	strncpy(buf, s, (size_t)n - 1);
	buf[n - 1] = 0;
}
*/
import "C"

import (
	"fmt"
	"os"
	"sync"
	"time"
	"unsafe"

	"github.com/windtf/wireproxy"
	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// The system-VPN entry points, used only by the iOS packet tunnel extension. The
// extension runs one tunnel in its own process, so state here is global:
//
//	TVVPNTunnelPrepare(conf)  parse the .conf and resolve its endpoint, BEFORE the
//	                          extension applies its network settings (after that,
//	                          resolving a name could be routed into a tunnel that is
//	                          not up yet)
//	TVVPNTunnelStart()        find the utun descriptor and run WireGuard on it
//	TVVPNTunnelStop()         stop it
//	TVVPNTunnelLog(buf, n)    the last lines wireguard-go and these functions logged:
//	                          an extension has no console, so this is how the app
//	                          reads what happened inside it

var (
	tmu     sync.Mutex
	pending *wireproxy.DeviceSetting
	running *device.Device

	logMu  sync.Mutex
	logBuf []byte
)

const logKeep = 16 << 10

func tlogf(format string, args ...any) {
	line := time.Now().Format("15:04:05 ") + fmt.Sprintf(format, args...) + "\n"
	logMu.Lock()
	logBuf = append(logBuf, line...)
	if len(logBuf) > logKeep {
		logBuf = logBuf[len(logBuf)-logKeep:]
	}
	logMu.Unlock()
}

func tfail(buf *C.char, n C.int, msg string) C.int {
	tlogf("%s", msg)
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.tvvpn_tunnel_seterr(buf, n, cs)
	return -1
}

//export TVVPNTunnelPrepare
func TVVPNTunnelPrepare(confText *C.char, errBuf *C.char, errLen C.int) (rc C.int) {
	defer func() {
		if r := recover(); r != nil {
			rc = tfail(errBuf, errLen, fmt.Sprint("internal error: ", r))
		}
	}()

	// wireproxy parses from a path; the extension's temp directory is its own.
	f, err := os.CreateTemp("", "tvvpn-*.conf")
	if err != nil {
		return tfail(errBuf, errLen, "writing the config: "+err.Error())
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(C.GoString(confText)); err != nil {
		f.Close()
		return tfail(errBuf, errLen, "writing the config: "+err.Error())
	}
	f.Close()

	conf, err := wireproxy.ParseConfig(f.Name())
	if err != nil {
		return tfail(errBuf, errLen, "parsing the config: "+err.Error())
	}
	setting, err := wireproxy.CreateIPCRequest(conf.Device)
	if err != nil {
		return tfail(errBuf, errLen, "preparing the tunnel: "+err.Error())
	}

	tmu.Lock()
	pending = setting
	tmu.Unlock()
	tlogf("prepared: %d address(es), %d dns, mtu %d", len(setting.DeviceAddr), len(setting.DNS), setting.MTU)
	return 0
}

//export TVVPNTunnelStart
func TVVPNTunnelStart(errBuf *C.char, errLen C.int) (rc C.int) {
	defer func() {
		if r := recover(); r != nil {
			rc = tfail(errBuf, errLen, fmt.Sprint("internal error: ", r))
		}
	}()

	tmu.Lock()
	defer tmu.Unlock()
	if pending == nil {
		return tfail(errBuf, errLen, "no prepared tunnel: TVVPNTunnelPrepare must succeed first")
	}
	if running != nil {
		return tfail(errBuf, errLen, "a tunnel is already running")
	}

	fd := int(C.tvvpn_find_utun_fd())
	if fd < 0 {
		return tfail(errBuf, errLen, "no utun descriptor found: were the network settings applied?")
	}
	tlogf("utun descriptor %d", fd)
	if err := unix.SetNonblock(fd, true); err != nil {
		return tfail(errBuf, errLen, "setting the descriptor non-blocking: "+err.Error())
	}

	// The MTU is already set by the system from the network settings, hence 0.
	tunDev, err := tun.CreateTUNFromFile(os.NewFile(uintptr(fd), "utun"), 0)
	if err != nil {
		return tfail(errBuf, errLen, "wrapping the tunnel: "+err.Error())
	}

	logger := &device.Logger{
		Verbosef: func(format string, args ...any) { tlogf("wg: "+format, args...) },
		Errorf:   func(format string, args ...any) { tlogf("wg ERROR: "+format, args...) },
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), logger)
	if err := dev.IpcSet(pending.IpcRequest); err != nil {
		dev.Close()
		return tfail(errBuf, errLen, "configuring wireguard: "+err.Error())
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return tfail(errBuf, errLen, "bringing wireguard up: "+err.Error())
	}

	running = dev
	tlogf("wireguard is up")
	return 0
}

//export TVVPNTunnelStop
func TVVPNTunnelStop() {
	tmu.Lock()
	dev := running
	running = nil
	pending = nil
	tmu.Unlock()
	if dev != nil {
		dev.Close()
		tlogf("wireguard stopped")
	}
}

// TVVPNTunnelLog copies the log into buf (NUL-terminated, truncated to n) and
// returns how many bytes it wrote.
//
//export TVVPNTunnelLog
func TVVPNTunnelLog(buf *C.char, n C.int) C.int {
	if buf == nil || n <= 0 {
		return 0
	}
	logMu.Lock()
	text := logBuf
	if len(text) > int(n)-1 {
		text = text[len(text)-(int(n)-1):]
	}
	out := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(n))
	copy(out, text)
	out[len(text)] = 0
	logMu.Unlock()
	return C.int(len(text))
}
