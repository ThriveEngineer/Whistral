//
//  TextInserter.swift
//  Whistral
//
//  Inserts transcribed text at the cursor of the frontmost app.
//

import AppKit
import Carbon.HIToolbox
import Foundation

enum TextInserter {

    /// Inserts text into the frontmost app. Call from the main thread.
    ///
    /// `expectedBundleID`: the bundle ID of the app that was frontmost when
    /// dictation began. If focus has verifiably moved elsewhere while the
    /// clipboard (paste) method is requested, insertion is ABORTED (returns
    /// `false`) rather than mis-typing into the new app — the transcript then
    /// lands on the clipboard via the caller's failure fallback. The abort
    /// covers only confirmed mismatches; unverifiable focus (nil frontmost or
    /// nil `expectedBundleID`) keeps the historical keystrokes downgrade.
    ///
    /// Returns whether the insertion was dispatched successfully: `false` for
    /// empty text, a focus mismatch on the paste path, a refused clipboard
    /// write, or a keystroke event that could not be created/posted. Note that
    /// keystroke delivery is best-effort by nature: some sandboxed/Electron
    /// apps silently drop synthetic Unicode events, which `true` cannot
    /// detect — only event creation/posting failures are observable.
    @discardableResult
    static func insert(_ text: String, method methodChoice: InsertionMethod, expectedBundleID: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var method = methodChoice
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focusChanged: Bool
        if let expectedBundleID, let frontmost {
            focusChanged = frontmost != expectedBundleID
        } else {
            // Fail closed: if focus can't be verified (frontmost app
            // unidentified mid app-switch, login screen, Spaces transition, or
            // capture began with no frontmost app at all), a blind paste could
            // land the text anywhere — fall back to synthetic keystrokes.
            focusChanged = true
        }

        if focusChanged {
            if let expectedBundleID, let frontmost, frontmost != expectedBundleID, method == .clipboard {
                // Confirmed focus change + user asked to paste: typing into the
                // newly-focused app is exactly the mis-insertion the capture-
                // time bundle ID exists to prevent, and the controller has a
                // lossless fallback (clipboard copy + HUD message). Aborting
                // inserted nothing, so there is nothing to clean up.
                return false
            }
            // Everything else (unverifiable focus, or the user explicitly chose
            // synthetic keystrokes and accepts that they type wherever focus
            // is) degrades from paste to keystrokes.
            method = .keystrokes
        }

        switch method {
        case .clipboard:
            return paste(trimmed)
        case .keystrokes:
            return type(trimmed)
        }
    }

    /// Writes text to the pasteboard only — no synthetic keystrokes. Used as a
    /// fallback when insertion fails: the transcript is preserved ("copy ready
    /// to paste") without re-attempting an insertion that already failed.
    static func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A deliberate user-facing copy; nothing is snapshotted/restored here.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
    }

    // MARK: - Keystrokes

    /// Simulates keypresses carrying the Unicode string. Works in most apps;
    /// some sandboxesed or Electron apps drop synthetic unicode events, which
    /// is why paste is the recommended method.
    ///
    /// Returns whether every chunk had its key events created and posted.
    /// Event creation failure is observable here; downstream apps silently
    /// dropping the synthetic events is not.
    private static func type(_ text: String) -> Bool {
        let chunks = splitForEvents(text)
        guard !chunks.isEmpty else { return false }
        var allPosted = true
        for chunk in chunks {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                // Event creation failed for this chunk: its text would be
                // missing, so the insertion must not read as success.
                allPosted = false
                continue
            }
            let utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000) // 8 ms between chunks; fast for humans, safe for apps
        }
        return allPosted
    }

    private static func splitForEvents(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.utf16.count >= 20 {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Paste

    private static func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        // Snapshot the previous pasteboard items BEFORE clearContents() — the
        // write below destroys them, so the snapshot must be complete up front:
        // payloads are captured as raw data (via data(forType:), falling back to
        // the UTF-8 string bytes) so items that carry non-string types (images,
        // file URLs) are still restorable. The old snapshot-then-post-guard ran
        // its "don't clobber non-string clipboards" check after the clobber.
        var previousItems: [[NSPasteboard.PasteboardType: Data]] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type)
                        ?? item.string(forType: type)?.data(using: .utf8) {
                        dict[type] = data
                    }
                    // Types with no readable payload (promised data, file
                    // promises) are simply left out of the restore.
                }
                if !dict.isEmpty { previousItems.append(dict) }
            }
        }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // The pasteboard refused the write before we even pasted: put the
            // user's clipboard back and report failure (the caller falls back
            // to copy-only + HUD instead of silently dropping the text).
            restore(previousItems, to: pasteboard)
            return false
        }
        let changeCountAfterWrite = pasteboard.changeCount

        sendCommandV()

        // Restore the previous clipboard contents shortly after so the
        // transient paste does not clobber the user's clipboard — but only
        // if nothing else (clipboard manager, user copy) changed it while the
        // paste was in flight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard pasteboard.changeCount == changeCountAfterWrite else { return }
            restore(previousItems, to: pasteboard)
        }
        return true
    }

    /// Re-writes snapshotted pasteboard items. Best effort: a type that no
    /// longer accepts data is skipped.
    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        for snapshot in items {
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    private static func sendCommandV() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }
}
