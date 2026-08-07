//go:build darwin

package main

import "github.com/ebitengine/purego/objc"

// NSAutoresizingMaskOptions
const (
	viewWidthSizable  = 1 << 1
	viewHeightSizable = 1 << 4
)

var (
	selInitWithFrame          = objc.RegisterName("initWithFrame:")
	selSetContentView         = objc.RegisterName("setContentView:")
	selSetAutoresizesSubviews = objc.RegisterName("setAutoresizesSubviews:")
	selSetAutoresizingMask    = objc.RegisterName("setAutoresizingMask:")
	selBounds                 = objc.RegisterName("bounds")
	selRetain                 = objc.RegisterName("retain")
)

// hostWebView puts a plain NSView between the window and the WKWebView, and
// reports whether it could.
//
// go-webview makes the web view the window's *contentView* directly. That is
// fine until the page takes an element fullscreen — the player's own fullscreen
// button — because WebKit implements that by pulling the web view out of its
// superview, parking it in a window of its own, and putting it back afterwards.
//
// `removeFromSuperview` on a contentView sets the window's contentView to nil,
// and WebKit restores the view by re-adding it to the superview it remembers,
// never by calling setContentView: again. So the window came back from
// fullscreen with contentView still nil and the web view hanging off the frame
// view with no autoresizing mask: the title collapsed onto the traffic lights,
// and the page stayed frozen at its old size in the bottom-left corner while
// the window resized around it.
//
// With a container in the way, the view WebKit removes and restores is an
// ordinary subview. The contentView is the container and stays put, so the
// titlebar is never disturbed, and the mask below — a property of the view,
// so it survives the round-trip — keeps the web view filling the container.
//
// Must run on the main thread, after webview.New and before the first
// Navigate. If it fails the app is still usable; only fullscreen suffers.
func (a *app) hostWebView() bool {
	view := a.webView()
	window := objc.ID(uintptr(a.w.Window()))
	classView := objc.GetClass("NSView")
	if view == 0 || window == 0 || classView == 0 {
		return false
	}

	// The web view is the contentView at this point, so its bounds are the
	// content rect — the frame the container wants, and the frame the view
	// wants inside it.
	bounds := objc.Send[nsRect](view, selBounds)

	container := objc.ID(classView).Send(selAlloc).Send(selInitWithFrame, bounds)
	if container == 0 {
		return false
	}
	container.Send(selSetAutoresizesSubviews, true)

	// setContentView: detaches the web view, and the window is the only thing
	// we can be sure was holding it. Retained and never released, like the
	// menus: it lives as long as the process does.
	view.Send(selRetain)
	window.Send(selSetContentView, container)
	container.Send(selAddSubview, view)
	view.Send(selSetFrame, bounds)
	view.Send(selSetAutoresizingMask, uint(viewWidthSizable|viewHeightSizable))

	return true
}
