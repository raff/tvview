//go:build darwin

package main

import (
	"runtime"
	"time"

	"github.com/ebitengine/purego/objc"
)

// How long a first Cmd-Q stays "armed", and how long the prompt stays up. The
// prompt outlives the arming window slightly so it never vanishes while the
// press would still count.
const (
	quitArmedFor  = 2 * time.Second
	quitPromptFor = 2500 * time.Millisecond
)

const quitPrompt = "Press ⌘Q again to Quit"

// NSEventType
const eventKeyDown = 10

// NSWindow and friends.
const (
	styleMaskBorderless  = 0
	backingStoreBuffered = 2

	// Above everything including a fullscreen window.
	levelScreenSaver = 1000

	behaviorCanJoinAllSpaces    = 1 << 0
	behaviorFullScreenAuxiliary = 1 << 8
)

type nsPoint struct{ X, Y float64 }
type nsSize struct{ Width, Height float64 }
type nsRect struct {
	Origin nsPoint
	Size   nsSize
}

var (
	selCurrentEvent     = objc.RegisterName("currentEvent")
	selType             = objc.RegisterName("type")
	selTerminate        = objc.RegisterName("terminate:")
	selInitContentRect  = objc.RegisterName("initWithContentRect:styleMask:backing:defer:")
	selSetLevel         = objc.RegisterName("setLevel:")
	selSetOpaque        = objc.RegisterName("setOpaque:")
	selSetBackgroundCol = objc.RegisterName("setBackgroundColor:")
	selSetCollectionBhv = objc.RegisterName("setCollectionBehavior:")
	selSetIgnoresMouse  = objc.RegisterName("setIgnoresMouseEvents:")
	selContentView      = objc.RegisterName("contentView")
	selCenter           = objc.RegisterName("center")
	selOrderFrontRegard = objc.RegisterName("orderFrontRegardless")
	selOrderOut         = objc.RegisterName("orderOut:")
	selSetWantsLayer    = objc.RegisterName("setWantsLayer:")
	selLayer            = objc.RegisterName("layer")
	selSetCornerRadius  = objc.RegisterName("setCornerRadius:")
	selClearColor       = objc.RegisterName("clearColor")
	selWhiteColor       = objc.RegisterName("whiteColor")
	selColorWhiteAlpha  = objc.RegisterName("colorWithCalibratedWhite:alpha:")
	selCGColor          = objc.RegisterName("CGColor")
	selLabelWithString  = objc.RegisterName("labelWithString:")
	selSetFrame         = objc.RegisterName("setFrame:")
	selSetAlignment     = objc.RegisterName("setAlignment:")
	selSetTextColor     = objc.RegisterName("setTextColor:")
	selSetFont          = objc.RegisterName("setFont:")
	selSystemFontOfSize = objc.RegisterName("systemFontOfSize:")
	selAddSubview       = objc.RegisterName("addSubview:")
)

// Touched only from the main thread: the menu action runs there, and the
// timer's callback hops back via Dispatch before it does anything.
var (
	quitArmedAt time.Time
	quitTimer   *time.Timer
	quitHUD     objc.ID
)

// alignCenter is NSTextAlignmentCenter, which macOS numbers differently
// depending on the ABI: x86_64 keeps AppKit's legacy ordering (right=1,
// center=2) while everything else uses the iOS values (center=1, right=2).
// See TARGET_ABI_USES_IOS_VALUES in AppKit's NSText.h. Getting it wrong
// silently left-or-right aligns the prompt rather than failing.
func alignCenter() int {
	if runtime.GOARCH == "amd64" {
		return 2
	}
	return 1
}

// requestQuit implements Chrome's asymmetry: choosing Quit from the menu is a
// deliberate act and takes effect at once, while Cmd-Q — easily hit when
// reaching for Cmd-W or Tab — has to be pressed twice.
//
// The two are told apart by the event that triggered the action. A key
// equivalent leaves a key-down as NSApp.currentEvent; a click leaves a mouse
// event.
//
// Both branches that actually quit call a.shutdown() first — the one seam
// this file has into whatever cleanup the rest of the app needs before the
// process ends, without this file needing to know what that is. It only
// blocks when there is something to tear down, and only up to
// quitVPNGrace, so quitting stays "at once" in the common case.
func (a *app) requestQuit() {
	app := objc.ID(classApplication).Send(selSharedApplication)

	event := app.Send(selCurrentEvent)
	fromKeyboard := event != 0 && objc.Send[int](event, selType) == eventKeyDown

	if !fromKeyboard {
		a.shutdown()
		app.Send(selTerminate, objc.ID(0))
		return
	}

	if !quitArmedAt.IsZero() && time.Since(quitArmedAt) <= quitArmedFor {
		a.shutdown()
		app.Send(selTerminate, objc.ID(0))
		return
	}

	quitArmedAt = time.Now()
	showQuitPrompt(a)
}

// showQuitPrompt puts the HUD on screen and schedules its removal.
//
// It is a borderless window rather than anything drawn in the page: the page
// is exactly where this has to work least — during playback, often
// fullscreen, where web content occupies the top layer and would cover a DOM
// toast. A window at screen-saver level with FullScreenAuxiliary sits above
// all of it.
func showQuitPrompt(a *app) {
	if quitHUD == 0 {
		quitHUD = buildQuitPrompt()
	}
	if quitHUD == 0 {
		return // could not build it; the double press still works
	}

	quitHUD.Send(selCenter)
	quitHUD.Send(selOrderFrontRegard)

	if quitTimer != nil {
		quitTimer.Stop()
	}
	quitTimer = time.AfterFunc(quitPromptFor, func() {
		a.w.Dispatch(func() {
			if quitHUD != 0 {
				quitHUD.Send(selOrderOut, objc.ID(0))
			}
		})
	})
}

// buildQuitPrompt makes the HUD once. Returns 0 if any class is missing, in
// which case quitting still works, just silently.
func buildQuitPrompt() objc.ID {
	classWindow := objc.GetClass("NSWindow")
	classColor := objc.GetClass("NSColor")
	classTextField := objc.GetClass("NSTextField")
	classFont := objc.GetClass("NSFont")
	if classWindow == 0 || classColor == 0 || classTextField == 0 || classFont == 0 {
		return 0
	}

	const (
		width   = 320.0
		height  = 86.0
		labelH  = 24.0
		fontPts = 16.0
	)

	frame := nsRect{Size: nsSize{Width: width, Height: height}}
	win := objc.ID(classWindow).Send(selAlloc).Send(selInitContentRect,
		frame, uint(styleMaskBorderless), uint(backingStoreBuffered), false)
	if win == 0 {
		return 0
	}

	win.Send(selSetLevel, levelScreenSaver)
	win.Send(selSetOpaque, false)
	win.Send(selSetBackgroundCol, objc.ID(classColor).Send(selClearColor))
	win.Send(selSetCollectionBhv, uint(behaviorCanJoinAllSpaces|behaviorFullScreenAuxiliary))
	win.Send(selSetIgnoresMouse, true)

	// The visible box is the content view's layer, so it can have rounded
	// corners; the window itself stays transparent.
	content := win.Send(selContentView)
	content.Send(selSetWantsLayer, true)
	layer := content.Send(selLayer)
	backing := objc.ID(classColor).Send(selColorWhiteAlpha, 0.0, 0.82)
	layer.Send(selSetBackgroundCol, backing.Send(selCGColor))
	layer.Send(selSetCornerRadius, 14.0)

	label := objc.ID(classTextField).Send(selLabelWithString, nsString(quitPrompt))
	label.Send(selSetFrame, nsRect{
		Origin: nsPoint{X: 0, Y: (height - labelH) / 2},
		Size:   nsSize{Width: width, Height: labelH},
	})
	label.Send(selSetAlignment, alignCenter())
	label.Send(selSetTextColor, objc.ID(classColor).Send(selWhiteColor))
	label.Send(selSetFont, objc.ID(classFont).Send(selSystemFontOfSize, fontPts))
	content.Send(selAddSubview, label)

	return win
}
