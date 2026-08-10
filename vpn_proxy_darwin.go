//go:build darwin

package main

import (
	"fmt"
	"strconv"
	"sync"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

// vpn_proxy_darwin.go points [WKWebsiteDataStore defaultDataStore] at a
// local SOCKS5 proxy, which is what actually scopes the tunnel to this
// app's own traffic instead of the whole machine.
//
// This works because proxyConfigurations is a real Objective-C property —
// NSArray<nw_proxy_config_t> *, API_AVAILABLE(macos(14.0)) in WebKit's own
// WKWebsiteDataStore.h — backed by Network.framework's plain C API, not the
// Swift-only NWEndpoint overlay. So no Swift and no cgo are needed here,
// just purego's objc bridge (already a dependency via go-webview) plus two
// C functions resolved directly out of Network.framework.
//
// Confirmed empirically (see the spike this replaced): setting this
// property redirects WKWebView's networking with no system-wide proxy
// state at all — a plain curl or a Safari tab on the same machine is
// untouched.
//
// go-webview has no API for handing a WKWebView its own data store, and
// every WKWebView it creates uses the default one, so mutating the shared
// [WKWebsiteDataStore defaultDataStore] is sufficient — there is nothing
// else in this process to target.

var (
	selDefaultDataStore       = objc.RegisterName("defaultDataStore")
	selSetProxyConfigurations = objc.RegisterName("setProxyConfigurations:")
	selArrayWithObject        = objc.RegisterName("arrayWithObject:")
	selRelease                = objc.RegisterName("release")
)

var (
	nwEndpointCreateHost       func(hostname, port string) uintptr
	nwProxyConfigCreateSocksv5 func(endpoint uintptr) uintptr

	proxyAPIOnce sync.Once
	proxyAPIErr  error
)

// initProxyAPI resolves the Network.framework symbols and confirms
// WKWebsiteDataStore is loaded, once. Deferred to first use — called after
// webview.New(), by which point go-webview has already pulled WebKit into
// the process — rather than a package init(), so a process that somehow
// ends up on macOS older than 14 (where these symbols genuinely don't
// exist) fails with one clear error from Ensure instead of a panic before
// main even starts.
func initProxyAPI() error {
	proxyAPIOnce.Do(func() {
		h, err := purego.Dlopen("/System/Library/Frameworks/Network.framework/Network", purego.RTLD_GLOBAL)
		if err != nil {
			proxyAPIErr = fmt.Errorf("loading Network.framework: %w", err)
			return
		}

		endpointSym, err := purego.Dlsym(h, "nw_endpoint_create_host")
		if err != nil {
			proxyAPIErr = fmt.Errorf("nw_endpoint_create_host: %w (macOS 14 or later is required)", err)
			return
		}
		socksSym, err := purego.Dlsym(h, "nw_proxy_config_create_socksv5")
		if err != nil {
			proxyAPIErr = fmt.Errorf("nw_proxy_config_create_socksv5: %w (macOS 14 or later is required)", err)
			return
		}
		purego.RegisterFunc(&nwEndpointCreateHost, endpointSym)
		purego.RegisterFunc(&nwProxyConfigCreateSocksv5, socksSym)

		if objc.GetClass("WKWebsiteDataStore") == 0 {
			proxyAPIErr = fmt.Errorf("WKWebsiteDataStore not available (macOS 14 or later is required)")
		}
	})
	return proxyAPIErr
}

func defaultDataStore() objc.ID {
	class := objc.GetClass("WKWebsiteDataStore")
	return objc.Send[objc.ID](objc.ID(class), selDefaultDataStore)
}

// setWebViewProxy routes the app's WKWebViews through a SOCKS5 proxy at
// 127.0.0.1:port.
func setWebViewProxy(port int) error {
	if err := initProxyAPI(); err != nil {
		return err
	}

	endpoint := nwEndpointCreateHost("127.0.0.1", strconv.Itoa(port))
	if endpoint == 0 {
		return fmt.Errorf("nw_endpoint_create_host returned nil")
	}
	proxyConfig := nwProxyConfigCreateSocksv5(endpoint)
	if proxyConfig == 0 {
		objc.ID(endpoint).Send(selRelease)
		return fmt.Errorf("nw_proxy_config_create_socksv5 returned nil")
	}

	array := objc.Send[objc.ID](objc.ID(objc.GetClass("NSArray")), selArrayWithObject, objc.ID(proxyConfig))
	defaultDataStore().Send(selSetProxyConfigurations, array)

	// Both nw_endpoint_create_host and nw_proxy_config_create_socksv5 are
	// NW_RETURNS_RETAINED: we own +1 on each. NSArray and
	// setProxyConfigurations: both took their own retain when we handed
	// the objects over, so ours is now spare.
	objc.ID(proxyConfig).Send(selRelease)
	objc.ID(endpoint).Send(selRelease)
	return nil
}

// clearWebViewProxy returns the app's WKWebViews to routing directly.
func clearWebViewProxy() error {
	if err := initProxyAPI(); err != nil {
		return err
	}
	// proxyConfigurations is nullable; nil clears it, no empty NSArray needed.
	defaultDataStore().Send(selSetProxyConfigurations, objc.ID(0))
	return nil
}
