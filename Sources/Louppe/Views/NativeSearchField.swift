import AppKit
import SwiftUI

/// Embedded native search with live binding updates and optional palette commands.
/// Focus requests are consumed once, only in the field's attached key window.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    var clearAccessibilityLabel: String? = nil
    var requiresExplicitFocus = false
    var focusRequested: Binding<Bool> = .constant(false)
    var onMove: ((Int) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchField {
        context.coordinator.makeField()
    }

    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.owner = self
        context.coordinator.update(field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: SearchField, coordinator: Coordinator) {
        coordinator.dismantle(field)
    }

    final class SearchField: NSSearchField {
        var windowDidChange: (() -> Void)?
        var requiresExplicitFocus = false

        override func mouseDown(with event: NSEvent) {
            refusesFirstResponder = false
            defer { refusesFirstResponder = requiresExplicitFocus }
            super.mouseDown(with: event)
        }

        override func setAccessibilityFocused(_ focused: Bool) {
            refusesFirstResponder = requiresExplicitFocus && !focused
            defer { refusesFirstResponder = requiresExplicitFocus }
            super.setAccessibilityFocused(focused)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window, window !== newWindow, currentEditor() != nil {
                window.makeFirstResponder(nil)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var owner: NativeSearchField
        private weak var field: SearchField?
        private weak var observedWindow: NSWindow?
        private var observedWindowID: ObjectIdentifier?
        private var observers: [NSObjectProtocol] = []
        private var lastFocusRequest = false
        private var focusPending = false
        private var focusGeneration = 0

        init(_ owner: NativeSearchField) { self.owner = owner }

        func makeField() -> SearchField {
            let field = SearchField(frame: .zero)
            self.field = field
            field.controlSize = .regular
            field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
            field.sendsWholeSearchString = false
            field.sendsSearchStringImmediately = true
            field.maximumRecents = 0
            field.delegate = self
            field.target = self
            field.action = #selector(searchChanged(_:))
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.windowDidChange = { [weak self, weak field] in
                guard let self, let field else { return }
                self.bindWindow(of: field)
            }
            update(field)
            return field
        }

        func update(_ field: SearchField) {
            // Settings search stays outside automatic focus; clicking and
            // explicit accessibility/programmatic requests can still edit it.
            field.requiresExplicitFocus = owner.requiresExplicitFocus
            field.refusesFirstResponder = owner.requiresExplicitFocus
            field.placeholderString = owner.placeholder
            field.setAccessibilityLabel(owner.accessibilityLabel)
            field.setAccessibilityIdentifier(owner.accessibilityIdentifier)
            if let label = owner.clearAccessibilityLabel {
                (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.setAccessibilityLabel(label)
            }
            synchronizeText(in: field)
            let requested = owner.focusRequested.wrappedValue
            if requested && !lastFocusRequest { focusPending = true }
            if !requested { focusPending = false }
            lastFocusRequest = requested
            scheduleFocus(in: field)
        }

        private func synchronizeText(in field: SearchField) {
            let editor = field.currentEditor() as? NSTextView
            // Reassigning stringValue even to the same value resets native caret,
            // selection and input-method state. Composition always owns its text.
            guard editor?.hasMarkedText() != true, field.stringValue != owner.text else { return }
            let selection = editor?.selectedRanges
            field.stringValue = owner.text
            if let editor, let selection {
                let length = (owner.text as NSString).length
                editor.selectedRanges = selection.map { value in
                    let range = value.rangeValue
                    let start = min(range.location, length)
                    return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? SearchField else { return }
            publishText(from: field)
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            // The native cancel button can send its action without an editing
            // notification. It must clear the same binding as ordinary typing.
            publishText(from: sender)
        }

        private func publishText(from field: NSSearchField) {
            if owner.text != field.stringValue { owner.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            route(commandSelector, editor: textView, event: NSApp.currentEvent)
        }

        func route(_ command: Selector, editor: NSTextView, event: NSEvent?) -> Bool {
            guard !editor.hasMarkedText() else { return false }
            if let event {
                var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if 123...126 ~= event.keyCode { modifiers.subtract([.numericPad, .function]) }
                if NSWorkspace.shared.isVoiceOverEnabled && modifiers.contains(.capsLock) { return false }
                modifiers.remove(.capsLock)
                guard modifiers.isEmpty else { return false }
            }
            switch command {
            case #selector(NSResponder.moveDown(_:)):
                guard let move = owner.onMove else { return false }
                move(1)
            case #selector(NSResponder.moveUp(_:)):
                guard let move = owner.onMove else { return false }
                move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                guard let submit = owner.onSubmit else { return false }
                submit()
            case #selector(NSResponder.cancelOperation(_:)):
                guard let cancel = owner.onCancel else { return false }
                cancel()
            default:
                return false
            }
            return true
        }

        private func bindWindow(of field: SearchField) {
            let windowID = field.window.map { ObjectIdentifier($0) }
            guard observedWindowID != windowID else { return }
            if observedWindowID != nil { cancelFocusRequest() }
            removeObservers()
            observedWindow = field.window
            observedWindowID = windowID
            guard let window = field.window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak field] notification in
                    let becameKey = notification.name == NSWindow.didBecomeKeyNotification
                    MainActor.assumeIsolated {
                        guard let self, let field, self.observedWindow === field.window else { return }
                        if becameKey {
                            self.scheduleFocus(in: field)
                        } else {
                            self.cancelFocusRequest()
                        }
                    }
                })
            }
            scheduleFocus(in: field)
        }

        private func scheduleFocus(in field: SearchField) {
            guard focusPending, let window = field.window, window.isKeyWindow else { return }
            let generation = focusGeneration
            DispatchQueue.main.async { [weak self, weak field, weak window] in
                guard let self, let field, let window,
                      self.focusGeneration == generation, self.focusPending,
                      self.owner.focusRequested.wrappedValue,
                      self.field === field, field.window === window,
                      self.observedWindow === window, window.isKeyWindow else { return }
                field.refusesFirstResponder = false
                defer { field.refusesFirstResponder = field.requiresExplicitFocus }
                if field.currentEditor() != nil || window.makeFirstResponder(field) {
                    self.focusPending = false
                    self.owner.focusRequested.wrappedValue = false
                }
            }
        }

        private func cancelFocusRequest() {
            focusGeneration += 1
            focusPending = false
            guard lastFocusRequest else { return }
            let generation = focusGeneration
            DispatchQueue.main.async { [self] in
                guard self.focusGeneration == generation else { return }
                self.owner.focusRequested.wrappedValue = false
            }
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        func dismantle(_ field: SearchField) {
            cancelFocusRequest()
            removeObservers()
            observedWindow = nil
            observedWindowID = nil
            field.windowDidChange = nil
            field.delegate = nil
            field.target = nil
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            self.field = nil
        }
    }
}
