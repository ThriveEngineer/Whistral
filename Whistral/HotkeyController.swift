//
//  HotkeyController.swift
//  Whistral
//
//  Global dictation shortcut built on a CGEventTap. Requires Accessibility
//  permission (granted during onboarding). The tap consumes the shortcut
//  keystrokes so they don't reach other apps.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import os.log

/// A keyboard shortcut: a virtual key code plus modifier flags (CGEventFlags bits).
struct Hotkey: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt64

    var display: String {
        var out = ""
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskCommand) { out += "⌘" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskShift) { out += "⇧" }
        out += Keys.name(forCode: keyCode)
        return out
    }

    static let `default` = Hotkey(
        keyCode: UInt32(kVK_Function),
        modifiers: 0
    )
}

final class HotkeyController {

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Keeps the callback-consumable unmanaged reference alive for the tap's lifetime.
    private var opaqueSelf: UnsafeMutableRawPointer?
    private var retainedSelf: HotkeyController?

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    var hotkey: Hotkey = .default
    var isEnabled = false

    /// True from the moment we consume a matching keyDown until the paired
    /// keyUp arrives. Only an armed press may be consumed on keyUp — otherwise
    /// every space keyUp in the whole system (plain spaces, ⌘Space Spotlight)
    /// would be swallowed, because the keyUp can't be modifier-matched
    /// reliably (the user may release ⌥ before Space).
    private var isArmed = false

    func enable(hotkey: Hotkey) {
        self.hotkey = hotkey
        disable()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue) |
                                (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let controller = Unmanaged<HotkeyController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handle(event: event, type: type)
        }

        // Retain for the lifetime of the tap.
        retainedSelf = self
        let opaque = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: opaque
        ) else {
            // Typically means Accessibility permission is missing.
            os_log("CGEventTap creation failed (missing Accessibility permission?)", type: .error)
            retainedSelf = nil
            Unmanaged<HotkeyController>.fromOpaque(opaque).release()
            return
        }

        eventTap = tap
        opaqueSelf = opaque
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isEnabled = true
        }
    }

    func disable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let opaque = opaqueSelf {
            Unmanaged<HotkeyController>.fromOpaque(opaque).release()
        }
        eventTap = nil
        runLoopSource = nil
        opaqueSelf = nil
        retainedSelf = nil
        isArmed = false
        isEnabled = false
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        // macOS can disable a tap under load; re-enable it — but debounce so
        // a persistently blocked backend can't spin the enable/disable loop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.isEnabled, !self.isArmed else { return }
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int(hotkey.keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            // Handle standalone modifier hotkeys like Fn (kVK_Function), Shift, etc.
            let isDown: Bool
            if keyCode == Int(kVK_Function) {
                isDown = event.flags.contains(.maskSecondaryFn)
            } else if keyCode == Int(kVK_Shift) || keyCode == Int(kVK_RightShift) {
                isDown = event.flags.contains(.maskShift)
            } else if keyCode == Int(kVK_Option) || keyCode == Int(kVK_RightOption) {
                isDown = event.flags.contains(.maskAlternate)
            } else if keyCode == Int(kVK_Command) || keyCode == Int(kVK_RightCommand) {
                isDown = event.flags.contains(.maskCommand)
            } else if keyCode == Int(kVK_Control) || keyCode == Int(kVK_RightControl) {
                isDown = event.flags.contains(.maskControl)
            } else if keyCode == Int(kVK_CapsLock) {
                isDown = event.flags.contains(.maskAlphaShift)
            } else {
                return Unmanaged.passUnretained(event)
            }

            if isDown {
                if !isArmed {
                    isArmed = true
                    onKeyDown?()
                }
                return nil
            } else {
                if isArmed {
                    isArmed = false
                    onKeyUp?()
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

        case .keyDown:
            // Require the exact modifier combo so ordinary presses pass through.
            let relevantMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let flags = event.flags.intersection(relevantMods)
            guard flags.rawValue == hotkey.modifiers else {
                return Unmanaged.passUnretained(event)
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                onKeyDown?()
                isArmed = true
                return nil // consume: ours
            }
            // Auto-repeat of our held press: consume so no stray spaces leak.
            return isArmed ? nil : Unmanaged.passUnretained(event)
        case .keyUp:
            // Consume only the keyUp of a press we actually took. Keyups are
            // modifier-flaky, so we don't re-match flags here — but an unarmed
            // space keyUp (plain typing, ⌘Space Spotlight, other apps) must
            // pass through untouched.
            if isArmed {
                isArmed = false
                onKeyUp?()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}

