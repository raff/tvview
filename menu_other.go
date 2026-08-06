//go:build !darwin

package main

// installMenuBar is a no-op off macOS. Windows and Linux do not route keyboard
// shortcuts through an application menu: WebView2 and WebKitGTK handle
// clipboard keys themselves, and the window manager handles closing.
func installMenuBar(*app) error { return nil }
