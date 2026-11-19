//
//  Keys.swift
//  Whistral
//
//  Virtual key code helpers (Carbon key codes, the same values CGEvent uses).
//

import AppKit
import Carbon.HIToolbox
import Foundation

enum Keys {

    /// Human-readable name for a virtual key code.
    static func name(forCode code: UInt32) -> String {
        if let named = namedKeys[Int(code)] { return named }

        // Letters and digits: A-Z map 0x00-0x12, digits 0x12-0x1D (US layout).
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        ]
        if let letter = letters[Int(code)] { return letter }

        let digits: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        if let digit = digits[Int(code)] { return digit }

        // Function keys F1-F20
        let f1 = UInt32(kVK_F1)
        let f20 = UInt32(kVK_F20)
        if code >= f1 && code <= f20 {
            return "F\(code - f1 + 1)"
        }

        return String(format: "Key %#04x", code)
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Tab: "Tab",
        kVK_Return: "Return",
        kVK_Escape: "Esc",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_CapsLock: "⇪",
        kVK_Function: "Fn",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
    ]

    /// This Mac's physical Fn/Globe key, often used for dictation.
    static let globeKeyCode: UInt32 = UInt32(kVK_Function)
}
