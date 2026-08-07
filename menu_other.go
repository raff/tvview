//go:build !darwin

package main

// installMenuBar is a no-op off macOS. Windows and Linux do not route keyboard
// shortcuts through an application menu: WebView2 and WebKitGTK handle
// clipboard keys themselves, and the window manager handles closing.
func installMenuBar(*app) error { return nil }

// setUserAgent is a no-op off macOS. WebView2 and WebKitGTK both have a knob
// for this, but go-webview does not expose the underlying widget on those
// platforms the way NSWindow's view tree lets us find the WKWebView.
func (*app) setUserAgent(string) bool { return false }
