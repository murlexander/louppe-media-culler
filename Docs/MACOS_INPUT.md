# macOS input and controls

Reviewed 28 October 2026 against Apple's touch talks, Human Interface Guidelines,
TN3212, and macOS 27.2 release notes. Runtime: macOS 27.2 (26B123). Installed
toolchain: Xcode 27.1 (27A9275), macOS 27.0 SDK. Deployment minimum remains macOS 14.

## Design rules

Keep the Mac's compact interface and support switching between keyboard,
pointer and touch. Apple's touch target recommendation is **36 × 36 points**
on Mac. Native controls adapt their touch behavior; use regular control sizing
in forms and inspectors and let toolbars choose their native presentation.
Expand a custom control's hit area before enlarging its icon. Avoid overlays
that cover the native control or intercept its touches.

Native menus adapt to the input that opens them. Keep sliders, steppers, menus
and grouped forms native so the OS can supply updated behavior. Small controls
can remain compact. Do not reproduce the talks' expanding controls with custom
popovers, or assume APIs from the forthcoming touch SDK exist in the installed
27.0 SDK.

Keep precise controls near the window edges and allow coarse pan/pinch gestures
on media. Duplicate gesture and modifier-only actions in visible controls or
menus. Hover can enhance feedback, but actions must remain available without
hover. Tooltips alone do not need a touch equivalent. Keep native system gestures.

## AppKit implementation

Direct touches reach gesture recognizers; they do not reach mouse responder
overrides, local/global event monitors or `NSWindow.sendEvent`. Use standard
view/control APIs first. Apple's implementation talk explicitly supports adding
touch-only recognizers alongside existing pointer tracking for an incremental
update: set `buttonMask = 0` and `allowedTouchTypes = .direct`.

Install recognizers on the hit-tested view or an ancestor. A transparent sibling
does not receive the underlying view's touches. Handle cancellation and let
tile taps yield to their enclosing scroll view with
`isCancellableByScrollGesture` on macOS 27+. Use a recognizer's modifier flags
instead of assuming `NSApp.currentEvent` owns a delayed action.

Browser/Grid keep native one-finger scrolling and pointer rubber-band selection.
Their native context menus provide Add/Remove from Selection and decision
actions for people working without modifier keys. The photo's native scroll
view owns touch pan and pinch; custom double-tap actions share the pointer's
existing zoom behavior. Fit remains an explicit onscreen action.

Tile menu actions retain the presented content revision and reject a changed
item at their original index, including while the menu is tracking.

Retain one adaptive glass surface per floating control group. Use interactive
glass for controls, with Reduce Motion disabling the extra effect; retain opaque
Reduce Transparency and older-system material fallbacks. Main-window Tab order
recalculates automatically when controls appear or disappear.

`NSIsTouchNative` is unchanged. This is an incremental native-input update;
end-to-end touch acceptance and the newer touch SDK remain separate checks.
Do not disable compatibility behavior or declare complete hardware support
based on synthetic mouse events or recognizer unit tests.

## Verification

`DirectTouchInteractionTests` checks direct-only input configuration, scroll
cancellation, simultaneous tap/double-tap recognition, input gates, native menu
actions, photo scroll ownership and Tab-order configuration. Existing Grid
control tests check immediate pointer selection, modifier-click, double-click,
drag suppression and repeated rating clicks. Zoom, playback, keyboard and
vertical-scroll regressions cover the affected shared controls.

Native layout captures must cover narrow/wide windows, Browser/Info visibility,
light/dark, RTL, Reduce Transparency, Increase Contrast and Reduce Motion.
Prefer unordered/offscreen fixtures; preserve the user's foreground and focus.

On 28 October, the final interaction/localization regression run passed 96 tests,
including complete Hotkey, BrowserScroll, GridScroll and
PersistentVerticalScroller suites. The safety/performance runner passed 75/75.
The native visual suite passed and produced 66 captures; reviewed affected
photo, Grid and narrow/wide playback layouts in light/dark and RTL/high-contrast
appearance. Offscreen captures do not verify live glass compositing. Reduce
Transparency and Reduce Motion system settings were not changed for this run.

The final 1.13.0 (15) package passed loose/archive preflight and signature
verification and was installed at `/Applications/Louppe.app`. A background launch
opened 40 disposable PNGs and saved all 40 session entries; every source hash
remained unchanged. The installed executable matches the packaged build.
Installed-app UI inspection was unavailable: ScreenCaptureKit failed twice with
`SCStreamErrorDomain -3811` (audio/video capture failure). No native input check
was counted as passing from that unavailable inspection. The background smoke
process was stopped after persistence verification; the previous app is retained
at `/private/tmp/Louppe-before-macos-input-wkqyz0md/Louppe.app`.

Real-touch acceptance requires a Mac touch display or connected Sidecar iPad:
tap/double-tap both Grid media and captions, long-press tile menus, add/remove
selection, rate, drag collections vertically without deciding/opening an item,
pan/pinch/double-tap photos, and operate Fit and playback sliders. Verify touch
cancellation and switch between touch, pointer, keyboard and VoiceOver. No
touch device was available for this review. The 27.2 SDK and macOS 14 runtime
were also unavailable; guarded compilation targets macOS 14 using SDK 27.0.

## Sources

- [Design for Touch on Mac](https://www.youtube.com/watch?v=2cq3ytwLrLk), also on
  [Apple Developer](https://developer.apple.com/videos/play/tech-talks/111456/).
  Reviewed the complete English caption track. Key sections: touch targets at
  9:14, hover at 11:39, expanding controls at 13:39.
- [Bring Touch to your Mac app](https://developer.apple.com/videos/play/tech-talks/111468/).
  Reviewed the English caption track: gesture migration, touch-only recognizers,
  hit targets, scrolling, cancellation and compatibility declaration.
- [HIG: Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)
  and [HIG: Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures).
- [TN3212: Adopting gesture recognizers for Sidecar touch support](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support).
- [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/):
  native input, automatic keyboard navigation, glass interaction and concentricity.
- [macOS 27.2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27_2-release-notes)
  and [Touch on Mac resources](https://developer.apple.com/touch-on-mac/):
  newer touch tools are listed separately from the installed SDK.

API availability was checked against installed AppKit headers and SwiftUI
interfaces, including NSClickGestureRecognizer, NSGestureRecognizer,
NSScrollView and Glass.interactive(_:).
