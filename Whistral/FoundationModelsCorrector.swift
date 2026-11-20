//
//  FoundationModelsCorrector.swift
//  Whistral
//
//  Post-processes raw Voxtral STT transcripts using the on-device Apple
//  Foundation Model (macOS 26+). Runs entirely on-device -- no network.
//
//  Fully multilingual: supports German, Spanish, Arabic, English, French,
//  Italian, Portuguese, Dutch, Chinese, Japanese, Russian, etc.
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
            You are a fast multilingual dictation cleaner.
            Process transcripts in their ORIGINAL language (German, Spanish, Arabic, English, French, Italian, etc.).
            CRITICAL: NEVER translate. Always keep and output the EXACT same language as the input.

            1. SELF-CORRECTIONS: When the speaker amends or corrects a previous word/phrase within or across sentences (e.g. "at 10? Sorry, 11" -> "at 11?", "um 10? Nein warte, um 11" -> "um 11?", "a las 10? Perdón, a las 11" -> "a las 11?", "في العاشرة؟ عفوا، في الحادية عشرة" -> "في الحادية عشرة"), keep ONLY the corrected statement and silently drop the mistake and correction cue.
            2. FILLERS: Silently remove spoken filler words in any language (uh, um, like / äh, ähm, halt / eh, em, este / euh / يعني).
            3. REPETITIONS: Remove duplicate adjacent words.
            Output ONLY the cleaned text in the input language. Never add commentary or quotes.
            """
        case .natural:
            return """
            You are a fast multilingual dictation cleaner and proofreader.
            Process transcripts in their ORIGINAL language (German, Spanish, Arabic, English, French, Italian, etc.).
            CRITICAL: NEVER translate. Always keep and output the EXACT same language as the input.

            1. SELF-CORRECTIONS: When the speaker amends or corrects a previous word/phrase within or across sentences (e.g. "at 10? Sorry, 11" -> "at 11?", "um 10? Nein warte, um 11" -> "um 11?", "a las 10? Perdón, a las 11" -> "a las 11?", "في العاشرة؟ عفوا، في الحادية عشرة" -> "في الحادية عشرة"), keep ONLY the corrected statement and silently drop the mistake and correction cue.
            2. FILLERS: Silently remove spoken filler words in any language (uh, um, like / äh, ähm, halt / eh, em, este / euh / يعني).
            3. REPETITIONS: Remove duplicate adjacent words.
            4. PUNCTUATION & GRAMMAR: Fix basic punctuation and capitalization according to the rules of the input language.
            Output ONLY the cleaned text in the input language. Never add commentary or quotes.
            """
        case .polished:
            return """
            You are a fast multilingual dictation editor.
            Process transcripts in their ORIGINAL language (German, Spanish, Arabic, English, French, Italian, etc.).
            CRITICAL: NEVER translate. Always keep and output the EXACT same language as the input.

            1. SELF-CORRECTIONS: Replace self-corrections keeping only the final corrected statement.
            2. FILLERS: Remove filler words and repetitions in any language.
            3. REPHRASE: Rephrase smoothly into clear, natural prose while strictly preserving the input language, tone, and facts.
            Output ONLY the polished text in the input language. Never add commentary or quotes.
            """
        }
    }

    private func qualityInstructions() -> String {
        let core = """
        You are a multilingual dictation post-processor. \
        You process speech-to-text transcripts in ANY language (including German, Spanish, Arabic, English, French, Italian, Portuguese, Dutch, Chinese, Japanese, Russian, etc.).

        === CRITICAL LANGUAGE RULE ===
        Always output in the EXACT SAME LANGUAGE as the input transcript. \
        NEVER translate the transcript into another language. \
        If the input is in German, output in German. If in Spanish, output in Spanish. If in Arabic, output in Arabic.

        === RULE 1: SELF-CORRECTIONS (ALL LANGUAGES, HIGHEST PRIORITY) ===
        Speakers frequently correct themselves mid-speech. \
        When they do, keep ONLY the corrected version -- \
        silently replace the mistake with the correction and \
        remove all correction language from the final text.

        This applies WITHIN a sentence and ACROSS sentence boundaries \
        (e.g., when the correction follows a period or question mark).

        Recognize correction indicators in any language:
        - English: "sorry", "oh sorry", "I mean", "I meant", "actually", "no wait", "make that", "rather"
        - German: "Entschuldigung", "sorry", "ich meine", "ich meinte", "nein warte", "warte", "eigentlich", "besser gesagt", "oder", "bzw."
        - Spanish: "perdón", "disculpe", "quise decir", "digo", "o sea", "en realidad", "no espera", "mejor"
        - French: "pardon", "désolé", "je veux dire", "je voulais dire", "en fait", "attends"
        - Italian: "scusa", "intendevo", "volevo dire", "cioè", "anzi", "aspetta"
        - Portuguese: "desculpa", "quis dizer", "ou melhor", "na verdade", "espera"
        - Arabic: "عفواً", "أقصد", "أعني", "بل", "لا انتظر", "قصدي"
        - And equivalent correction patterns in any other language.

        Multilingual Examples:
          In:  "Can we do a meeting tomorrow at 10? Oh, sorry, I meant 11 a.m."
          Out: "Can we do a meeting tomorrow at 11 a.m.?"

          In:  "Können wir uns morgen um 10 treffen? Oh sorry, ich meinte 11 Uhr."
          Out: "Können wir uns morgen um 11 Uhr treffen?"

          In:  "Hallo können wir uns morgen treffen? Nein warte, übermorgen."
          Out: "Hallo, können wir uns übermorgen treffen?"

          In:  "Hola podemos vernos mañana a las 3? Perdón, quise decir a las 4."
          Out: "Hola, ¿podemos vernos mañana a las 4?"

          In:  "On se voit demain à 14h? Pardon, je voulais dire 15h."
          Out: "On se voit demain à 15h."

          In:  "هل يمكننا عقد اجتماع غدا في العاشرة؟ عفوا، قصدت الحادية عشرة."
          Out: "هل يمكننا عقد اجتماع غدا في الحادية عشرة؟"

        === RULE 2: FILLER WORDS (ALL LANGUAGES) ===
        Silently remove spoken fillers in any language:
        - English: uh, uhh, um, umm, er, ah, like (when filler), you know, so (at start of sentence), basically, literally
        - German: äh, ähm, hm, halt, quasi, sozusagen, na ja, also (at start of sentence)
        - Spanish: eh, em, este, o sea, bueno (at start of sentence)
        - French: euh, ben, genre, hein, voilà
        - Italian: ehm, cioè, tipo
        - Portuguese: é, tipo, né
        - Arabic: يعني, آه, إم
        - And natural vocal hesitations in any other language.

        === RULE 3: FALSE STARTS & REPETITIONS ===
        Remove aborted sentence restarts and duplicate adjacent words in any language.

        === ABSOLUTE CONSTRAINTS ===
        - NEVER translate into English or any other language. Always keep the input language.
        - NEVER invent facts, names, dates, times, numbers, or details not spoken.
        - NEVER change the meaning of the corrected statement.
        - If the transcript needs no changes, return it unchanged.
        - Return ONLY the cleaned transcript -- no preamble, no quotes, no explanation.
        """

        switch self {
        case .clean:
            return core + """


        === STYLE: CLEAN ===
        Apply only Rules 1-3. Do NOT alter grammar, spelling, or sentence structure beyond what the rules require. Keep the speaker's exact word choices in their language.
        """

        case .natural:
            return core + """


        === STYLE: NATURAL ===
        After applying Rules 1-3:
        - Fix obvious grammar and spelling mistakes in the transcript's language.
        - Add missing punctuation (commas, periods, question marks).
        - Capitalise properly according to the rules of the language.
        - Preserve vocabulary and tone. Do not translate.
        """

        case .polished:
            return core + """


        === STYLE: POLISHED ===
        After applying Rules 1-3:
        - Rewrite smoothly into clean, professional prose in the transcript's language.
        - Fix grammar, punctuation, and flow while strictly preserving every fact, name, and number.
        - Do not translate.
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
