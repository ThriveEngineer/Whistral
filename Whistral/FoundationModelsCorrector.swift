//
//  FoundationModelsCorrector.swift
//  Whistral
//
//  Post-processes raw Voxtral STT transcripts using the on-device Apple
//  Foundation Model (macOS 26+). Runs entirely on-device -- no network.
//
//  Handles:
//    * Self-corrections, including cross-sentence ones:
//        "Can we meet at 10? Oh sorry, I meant 11 a.m."
//        -> "Can we meet at 11 a.m.?"
//
//    * Filler word removal:
//        "so uhh can we uhm schedule a call"
//        -> "Can we schedule a call?"
//
//    * False starts & repetitions:
//        "Let's -- Can we move the meeting" -> "Can we move the meeting"
//        "the the report is is done"        -> "the report is done"
//
//  Falls back to the raw transcript on any error so the dictation path
//  is never blocked.
//

import Foundation
import FoundationModels

// MARK: - Correction style

enum CorrectionStyle: String, CaseIterable, Identifiable {

    /// Remove fillers and resolve self-corrections, keep everything else verbatim.
    case clean = "clean"

    /// Clean + fix grammar/punctuation. Closest to Whisper Flow behaviour.
    case natural = "natural"

    /// Full editorial rewrite into polished prose. Most aggressive.
    case polished = "polished"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clean:    return "Clean -- remove fillers & self-corrections only"
        case .natural:  return "Natural -- also fix grammar & punctuation"
        case .polished: return "Polished -- rewrite into clean prose"
        }
    }

    // MARK: - Instructions (system prompt)

    /// Passed to LanguageModelSession(instructions:) so the model treats it
    /// as a true system prompt rather than part of the user turn.
    fileprivate var instructions: String {
        // Shared rules used by every style.
        let core = """
        You are a dictation post-processor. \
        Your sole job is to clean up a raw voice-to-text transcript.

        === RULE 1: SELF-CORRECTIONS (highest priority) ===
        Speakers often correct themselves mid-speech. \
        When they do, keep ONLY the corrected value -- \
        silently replace the wrong part with the correction and \
        remove all correction language from the final text.

        Correction signals include (but are not limited to):
          "oh sorry", "sorry", "I mean", "I meant", "actually",
          "no wait", "no", "correction", "strike that", "scratch that",
          "I should say", "rather", "or rather", "make that", "I mean to say"

        IMPORTANT: corrections often come as a SEPARATE sentence that follows
        the original sentence, e.g. after a period or question mark.
        You must look across sentence boundaries for corrections.

        Examples (study these carefully):
          In:  "Can we do a meeting tomorrow at 10? Oh, sorry, I meant 11 a.m."
          Out: "Can we do a meeting tomorrow at 11 a.m.?"

          In:  "Let's meet at 10am, oh sorry I meant 11am"
          Out: "Let's meet at 11 a.m."

          In:  "Send it to John. Actually, I mean Sarah."
          Out: "Send it to Sarah."

          In:  "The budget is 5000. No wait, 6000 dollars."
          Out: "The budget is 6,000 dollars."

          In:  "Call me at 3pm. Sorry, make that 4pm."
          Out: "Call me at 4 p.m."

          In:  "I need 10 copies. Oh actually, 12 copies."
          Out: "I need 12 copies."

        === RULE 2: FILLER WORDS ===
        Silently remove spoken filler words:
          uh, uhh, uhm, um, umm, hmm, hm, ah, ahh, er,
          "you know", "sort of", "kind of",
          "like" (when used as filler, not as a verb/preposition),
          "right" (when used as filler at start/end of clause),
          "so" (only when used as a sentence-opening filler),
          "basically", "literally" (when filler)

        === RULE 3: FALSE STARTS & WORD REPETITIONS ===
        Remove abandoned fragments where the speaker restarted:
          "Can we -- Can we schedule" -> "Can we schedule"
        Remove immediate word repetitions:
          "the the" -> "the", "is is" -> "is"

        === ABSOLUTE CONSTRAINTS ===
        - NEVER invent facts, names, times, numbers, or any content not spoken.
        - NEVER change the meaning of the corrected version.
        - NEVER add words that were not spoken (beyond punctuation).
        - If the transcript needs no changes, return it exactly as-is.
        - Return ONLY the cleaned transcript -- no preamble, no quotes, no explanation.
        """

        switch self {
        case .clean:
            return core + """


        === STYLE: CLEAN ===
        Apply only the rules above. \
        Do NOT fix grammar, spelling, or sentence structure beyond what the rules require. \
        Keep the speaker's exact word choices.
        """

        case .natural:
            return core + """


        === STYLE: NATURAL ===
        After applying the rules above, also:
        - Fix obvious grammar mistakes
        - Add missing punctuation (commas, periods, question marks)
        - Capitalise the first word of the result
        - Normalise time formats (e.g. "11 a.m." or "11am" -- be consistent)
        Do NOT restructure sentences or change vocabulary beyond these fixes.
        """

        case .polished:
            return core + """


        === STYLE: POLISHED ===
        After applying the rules above, rewrite into clean professional prose:
        - Fix all grammar, punctuation, and sentence structure
        - Improve flow and clarity
        - Preserve every fact, name, number, and decision the speaker stated
        """
        }
    }
}

// MARK: - Corrector

enum FoundationModelsCorrector {

    // One session per style so each has its own instruction context baked in.
    private static var sessions: [CorrectionStyle: LanguageModelSession] = [:]

    /// Cleans `text` with the on-device Foundation Model.
    /// Returns the original `text` unchanged on any error.
    @MainActor
    static func correct(text: String, style: CorrectionStyle) async -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return text }

        do {
            let s = try getSession(for: style)
            // The user turn is just the raw transcript -- the system/instruction
            // context is set on the session itself via instructions:
            let response = try await s.respond(to: Prompt(input))
            var result = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !result.isEmpty else { return input }
            // Safety: reject output that is implausibly longer than the input.
            guard result.count <= input.count * 4 else {
#if DEBUG
                print("[Corrector] output too long, using original")
#endif
                return input
            }
            return result

        } catch {
#if DEBUG
            print("[Corrector] error:", error.localizedDescription)
#endif
            sessions[style] = nil  // reset so next call tries a fresh session
            return input
        }
    }

    /// Whether the on-device Apple Intelligence model is available.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: - Private

    @MainActor
    private static func getSession(for style: CorrectionStyle) throws -> LanguageModelSession {
        if let existing = sessions[style] { return existing }
        guard SystemLanguageModel.default.isAvailable else {
            throw CorrectorError.modelUnavailable
        }
        // LanguageModelSession(instructions:) sets a true system prompt,
        // giving the model the right role framing separate from the user turn.
        let s = LanguageModelSession(instructions: style.instructions)
        sessions[style] = s
        return s
    }
}

// MARK: - Error

private enum CorrectorError: LocalizedError {
    case modelUnavailable
    var errorDescription: String? {
        "Apple Intelligence is not available on this device or has not been enabled."
    }
}
