import AppKit

/// Adds direct-touch actions to a custom pointer surface without intercepting
/// mouse events or placing another hit-testable view above native controls.
/// Apple recommends this bridge when retaining latency-sensitive mouse tracking.
@MainActor
final class DirectTouchClickActions: NSObject, NSGestureRecognizerDelegate {
    var singleTap: ((NSPoint, NSEvent.ModifierFlags) -> Void)?
    var doubleTap: ((NSPoint) -> Void)?
    private(set) var recognizers: [NSClickGestureRecognizer] = []

    func install(on view: NSView, includesSingleTap: Bool = false) {
        guard #available(macOS 27.0, *), recognizers.isEmpty else { return }
        for count in includesSingleTap ? [1, 2] : [2] {
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(activate(_:)))
            recognizer.buttonMask = 0 // Direct touches only; keep immediate mouse handling.
            recognizer.allowedTouchTypes = .direct
            recognizer.numberOfClicksRequired = count
            recognizer.isCancellableByScrollGesture = true
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            recognizers.append(recognizer)
        }
    }

    @objc func activate(_ recognizer: NSClickGestureRecognizer) {
        guard #available(macOS 27.0, *), recognizer.state == .ended, let view = recognizer.view,
              let window = view.window, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !view.isHiddenOrHasHiddenAncestor else { return }
        let point = recognizer.location(in: view)
        guard view.visibleRect.contains(point) else { return }
        if recognizer.numberOfClicksRequired == 2 {
            doubleTap?(point)
        } else {
            singleTap?(point, recognizer.modifierFlags)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        // Select on the first tap without waiting out the double-tap interval.
        // Do not opt into simultaneous recognition with scrolling or controls.
        recognizers.contains { $0 === gestureRecognizer }
            && recognizers.contains { $0 === otherGestureRecognizer }
    }
}
