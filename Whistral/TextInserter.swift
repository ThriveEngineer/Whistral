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
    static func insert(_ text: String, method: InsertionMethod) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch method {
        case .clipboard:
            paste(trimmed)
        case .keystrokes:
            type(trimmed)
        }
    }

    // MARK: - Keystrokes

    /// Simulates keypresses carrying the Unicode string. Works in most apps;
    /// some sandboxesed or Electron apps drop synthetic unicode events,
    /// which is why paste is the recommended method.
    private static func type(_ text: String) {
        let chunks = splitForEvents(text)
        for chunk in chunks {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            let utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000) // 8 ms between chunks; fast for humans, safe for apps
        }
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

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Snapshot previous pasteboard items so we can restore them.
        var previousItems: [[String: String]] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                var dict: [String: String] = [:]
                for type in item.types {
                    if let value = item.string(forType: type) {
                        dict[type.rawValue] = value
                    }
                }
                if !dict.isEmpty { previousItems.append(dict) }
            }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendCommandV()

        // Restore the previous clipboard contents shortly after so the
        // transient paste does not clobber the user's clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard !previousItems.isEmpty else { return }
            pasteboard.clearContents()
            for dict in previousItems {
                let item = NSPasteboardItem()
                for (key, value) in dict {
                    item.setString(value, forType: NSPasteboard.PasteboardType(key))
                }
                pasteboard.writeObjects([item])
            }
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
