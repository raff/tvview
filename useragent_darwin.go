//go:build darwin

package main

import "github.com/ebitengine/purego/objc"

var selSetCustomUserAgent = objc.RegisterName("setCustomUserAgent:")

// setUserAgent makes the web view claim to be ua, and reports whether it could.
//
// WKWebView's -setCustomUserAgent: replaces the string outright, for the top
// document and for every subresource and iframe under it — which is the part
// that matters here, since the player is usually somebody else's frame.
//
// Must be called on the main thread, and before the first Navigate: a page that
// has already asked who we are will not ask again.
func (a *app) setUserAgent(ua string) bool {
	view := a.webView()
	if view == 0 {
		return false
	}

	view.Send(selSetCustomUserAgent, nsString(ua))
	return true
}
