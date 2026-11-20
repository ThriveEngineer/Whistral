//
//  FoundationModelsCorrector.swift
//  Whistral
//
//  Post-processes raw Voxtral STT transcripts using the on-device Apple
//  Foundation Model (macOS 26+). Runs entirely on-device -- no network.
//
//  Supports two modes:
//    * Speed: low-latency, compact prompt for fast filler & self-correction removal
//    * Quality: deep contextual analysis with cross-sentence resolution
//

import Foundation
import FoundationModels

// MARK: - Correction mode (Speed vs Quality)

enum CorrectionMode: String, CaseIterable, Identifiable {
    case speed = "speed"
    case quality = "quality"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speed:   return "Speed (Fast) -- lower latency"
        case .quality: return "Quality (Accurate) -- deeper context"
        }
    }
}

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

    /// Builds instructions according to both the style and the quality/speed mode.
    fileprivate func instructions(mode: CorrectionMode) -> String {
        switch mode {
        case .speed:
            return speedInstructions()
        case .quality:
            return qualityInstructions()
        }
    }

    private func speedInstructions() -> String {
        switch self {
        case .clean:
            return """
            You are a fast dictation cleaner.
            1. Replace self-corrections (e.g. "at 10, sorry 11" -> "at 11") keeping only the corrected text.
            2. Remove spoken fillers: uh, uhh, um, umm, er, ah, like, you know.
            3. Remove repeated words ("the the" -> "the").
            Output ONLY the cleaned text. Never add commentary or quotes.
            """
        case .natural:
            return """
            You are a fast dictation cleaner and proofreader.
            1. Replace self-corrections (e.g. "tomorrow at 10? Oh sorry, I meant 11" -> "tomorrow at 11?") keeping only the correction.
            2. Remove fillers: uh, uhh, um, umm, er, ah, like, you know.
            3. Remove duplicate words.
            4. Fix basic punctuation and grammar.
            Output ONLY the cleaned text. Never add commentary or quotes.
            """
        case .polished:
            return """
            You are a fast dictation editor.
            1. Replace self-corrections keeping only the correction.
            2. Remove fillers (uh, um, er, like, you know) and repeated words.
            3. Rephrase smoothly into clear, professional prose while preserving all facts.
            Output ONLY the polished text. Never add commentary or quotes.
            """
        }
    }

    private func qualityInstructions() -> String {
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

    private struct SessionKey: Hashable {
        let style: CorrectionStyle
        let mode: CorrectionMode
    }

    private static var sessions: [SessionKey: LanguageModelSession] = [:]

    /// Cleans `text` with the on-device Foundation Model.
    /// Returns the original `text` unchanged on any error.
    @MainActor
    static func correct(text: String, style: CorrectionStyle, mode: CorrectionMode = .naturalMode) async -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return text }

        do {
            let s = try getSession(for: style, mode: mode)
            let response = try await s.respond(to: Prompt(input))
            var result = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !result.isEmpty else { return input }
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
            sessions[SessionKey(style: style, mode: mode)] = nil
            return input
        }
    }

    /// Prewarms the session in advance (e.g. when dictation starts)
    /// to eliminate cold-start latency when dictation ends.
    @MainActor
    static func prewarm(style: CorrectionStyle, mode: CorrectionMode) {
        guard isAvailable else { return }
        _ = try? getSession(for: style, mode: mode)
    }

    /// Whether the on-device Apple Intelligence model is available.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: - Private

    @MainActor
    private static func getSession(for style: CorrectionStyle, mode: CorrectionMode) throws -> LanguageModelSession {
        let key = SessionKey(style: style, mode: mode)
        if let existing = sessions[key] { return existing }
        guard SystemLanguageModel.default.isAvailable else {
            throw CorrectorError.modelUnavailable
        }
        let s = LanguageModelSession(instructions: style.instructions(mode: mode))
        sessions[key] = s
        return s
    }
}

// MARK: - Default mode extension

private extension CorrectionMode {
    static var naturalMode: CorrectionMode { .quality }
}

// MARK: - Error

private enum CorrectorError: LocalizedError {
    case modelUnavailable
    var errorDescription: String? {
        "Apple Intelligence is not available on this device or has not been enabled."
    }
}
