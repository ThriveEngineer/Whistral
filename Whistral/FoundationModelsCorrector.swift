//
//  FoundationModelsCorrector.swift
//  Whistral
//
//  Post-processes raw Voxtral STT transcripts using the on-device Apple
//  Foundation Model (macOS 26+). Runs entirely on-device -- no network.
//
//  Fully multilingual: English, German, Spanish, French, Italian, Portuguese,
//  Arabic, Dutch, Korean, Japanese, Russian, Chinese, Turkish.
//
//  Supports two modes:
//    * Speed: low-latency, compact prompt for fast filler & self-correction removal
//    * Quality: deep contextual analysis with cross-sentence resolution & intent preservation

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

    // MARK: Speed Instructions

    private func speedInstructions() -> String {
        let correctionExamples = """
        Self-correction examples (apply same logic in ANY language):
          "meet at 10? No wait, 11" -> "meet at 11"
          "um 10? Nein warte, um 11" -> "um 11"
          "a las 10? Perdón, a las 11" -> "a las 11"
          "10h? Pardon, 11h" -> "11h"
          "Let's call David -- sorry, I mean Michael" -> "Let's call Michael"
          "send 5 copies, make that 10" -> "send 10 copies"
          "في العاشرة؟ عفوا، في الحادية عشرة" -> "في الحادية عشرة"
          "morgen? Ich meine, ich meinte ubermorgen" -> "ubermorgen"
          "10시에? 아니, 잠깐, 11시에" -> "11시에"
          "明天10点? 不对, 11点" -> "明天11点"
          "Please email Sarah. No wait, email John." -> "Please email John."
          "Lass uns nach Hamburg fahren. Oder nee, besser nach Berlin." -> "Lass uns nach Berlin fahren."
        """

        let preservationNote = """
        INTENT PRESERVATION (DO NOT DESTROY):
        - Do NOT remove genuine apologies ("Sorry for being late", "Entschuldigung für die Verspätung", "Perdón por la demora").
        - Do NOT remove additive statements ("Actually, also send the file" -> keep both).
        - Only remove self-correction phrases when they clearly replace an accidental speech slip.
        """

        let cueLine = """
        Correction cues to detect: sorry/no wait/I mean/actually/make that (EN) | \
        Entschuldigung/nein/warte/ich meine/ich meinte/warte mal/eigentlich/vielmehr/besser gesagt/korrigiere/ahm nein (DE) | \
        perdon/no espera/espera/quise decir/digo/o sea/en realidad/me corrijo/es decir/a ver/o mejor dicho (ES) | \
        pardon/non/plutot/je veux dire/je voulais dire/en fait/attends/je me reprends/c'est-a-dire/ou plutot (FR) | \
        scusa/no aspetta/anzi no/intendevo/volevo dire/cioe/anzi/aspetta/mi correggo/o meglio (IT) | \
        desculpa/quer dizer/alias/quis dizer/ou melhor/na verdade/espera/me corrijo/melhor dizendo (PT) | \
        afwan/aqsid/la intazar/la bal/tas-hih/fi al-waqi (AR, transliterated) | \
        sorry/ik bedoel/nee wacht/eigenlijk/of liever/beter gezegd (NL) | \
        hayir bekle/yani/demek istedigim/ozur dilerim (TR) | \
        net podojdite/ya imeyu v vidu/tochnee/vernee/net (RU, transliterated) | \
        bu dui/wo de yi si shi/ying gai shi/jiu zheng yi xia (ZH, transliterated) | \
        iya/sumimasen/tsumari/de wa naku/訂正/janakute (JA) | \
        joesong/je mal eun/ani/jab-kan/jeong-hwal-hi-neun (KO, transliterated)
        """

        let fillerLine = """
        Filler words to silently remove: uh/um/er/ah/like/you know (EN) | \
        ah/ahm/hm/halt/quasi/sozusagen/na ja (DE) | \
        eh/em/este/bueno/o sea (ES) | \
        euh/ben/genre/hein (FR) | \
        ehm/cioe/tipo (IT) | \
        e/tipo/ne (PT) | \
        ya3ni/ah/im (AR) | \
        uhm/eh/nou/zeg maar (NL) | \
        eo/eum/geu/mwo/jeo (KO) | \
        eto/nu/tak/vot/korotche (RU) | \
        na ge/jiu shi/ran hou/zhe ge (ZH) | \
        eto/ano/sono/nanka (JA) | \
        sey/yani/iste (TR)
        """

        switch self {
        case .clean:
            return """
            You are a fast multilingual dictation cleaner.
            Process transcripts in their ORIGINAL language (German, Spanish, Arabic, English, French, Italian, Dutch, Japanese, Korean, Russian, Chinese, Turkish, etc.).
            CRITICAL: NEVER translate. Always keep and output the EXACT same language as the input.

            1. SELF-CORRECTIONS: When the speaker corrects a previous word/phrase (within or across sentences), keep ONLY the corrected statement. Drop the mistake and correction cue.
            \(correctionExamples)
            \(preservationNote)
            \(cueLine)

            2. FILLERS: Silently remove spoken filler words in any language.
            \(fillerLine)

            3. REPETITIONS: Remove duplicate adjacent words.

            Output ONLY the cleaned text in the input language. Never add commentary or quotes.
            """
        case .natural:
            return """
            You are a fast multilingual dictation cleaner and proofreader.
            Process transcripts in their ORIGINAL language (German, Spanish, Arabic, English, French, Italian, Dutch, Japanese, Korean, Russian, Chinese, Turkish, etc.).
            CRITICAL: NEVER translate. Always keep and output the EXACT same language as the input.

            1. SELF-CORRECTIONS: When the speaker corrects a previous word/phrase (within or across sentences), keep ONLY the corrected statement. Drop the mistake and correction cue.
            \(correctionExamples)
            \(preservationNote)
            \(cueLine)

            2. FILLERS: Silently remove spoken filler words in any language.
            \(fillerLine)

            3. REPETITIONS: Remove duplicate adjacent words.
            4. PUNCTUATION & GRAMMAR: Fix basic punctuation and capitalization according to the rules of the input language.

            Output ONLY the cleaned text in the input language. Never add commentary or quotes.
            """
        case .polished:
            return """
            You are a fast multilingual dictation editor.
            Process transcripts in their ORIGINAL language (German, Spanish, Arabic, English, French, Italian, Dutch, Japanese, Korean, Russian, Chinese, Turkish, etc.).
            CRITICAL: NEVER translate. Always keep and output the EXACT same language as the input.

            1. SELF-CORRECTIONS: When the speaker corrects themselves, keep ONLY the final corrected statement. Drop the mistake and cue.
            \(correctionExamples)
            \(preservationNote)
            \(cueLine)

            2. FILLERS: Remove all spoken filler words and repetitions.
            \(fillerLine)

            3. REPHRASE: Rephrase smoothly into clear, natural prose while strictly preserving the input language, tone, and facts.

            Output ONLY the polished text in the input language. Never add commentary or quotes.
            """
        }
    }

    // MARK: Quality Instructions

    private func qualityInstructions() -> String {
        let core = """
        You are a multilingual dictation post-processor. \
        You process speech-to-text transcripts in ANY language \
        (English, German, Spanish, French, Italian, Portuguese, Arabic, Dutch, Korean, Japanese, Russian, Chinese, Turkish, etc.).

        === CRITICAL LANGUAGE RULE ===
        Always output in the EXACT SAME LANGUAGE as the input transcript. \
        NEVER translate the transcript into another language. \
        If the input is German, output German. If Spanish, output Spanish. If Arabic, output Arabic. If Korean, output Korean.

        === RULE 1: SELF-CORRECTIONS & CROSS-SENTENCE RESOLUTION (HIGHEST PRIORITY) ===
        Speakers frequently correct themselves mid-speech, both WITHIN a sentence and ACROSS sentence boundaries \
        (where the correction follows in the next sentence after a period or question mark). \
        When a correction occurs: replace the mistake with the corrected statement, keeping the final intended meaning \
        and removing the spoken slip and correction markers.

        DEEPENED CORRECTION SIGNALS BY LANGUAGE:
        - English:    "sorry", "oh sorry", "I mean", "I meant", "actually", "no wait", "no, wait", "make that", "rather", "or rather", "correction", "let me rephrase", "scratch that", "on second thought", "I misspoke", "what I meant to say was"
        - German:     "Entschuldigung", "sorry", "ich meine", "ich meinte", "ich meinte zu sagen", "nein", "nein warte", "warte", "warte mal", "eigentlich", "vielmehr", "besser gesagt", "oder", "bzw.", "korrektur", "das war falsch", "ahm nein", "korrigiere mich", "Moment mal", "lass mich korrigieren", "ich habe mich versprochen", "ach Quatsch"
        - Spanish:    "perdon", "disculpe", "quise decir", "digo", "o sea", "en realidad", "no espera", "espera", "mejor", "a ver", "o mejor dicho", "no", "correccion", "me corrijo", "quiero decir", "diria mejor", "es decir", "espera un momento", "quise decir en realidad", "perdon me equivoque"
        - French:     "pardon", "desole", "je veux dire", "je voulais dire", "en fait", "attends", "non", "plutot", "enfin", "correction", "je me reprends", "j'entends", "c'est-a-dire", "ou plutot", "veux mieux dire", "attends une seconde", "je me suis trompe", "non je rectifie"
        - Italian:    "scusa", "intendevo", "volevo dire", "cioe", "anzi", "aspetta", "no aspetta", "anzi no", "mi correggo", "voglio dire", "piuttosto", "o meglio", "per essere preciso", "aspetta un attimo", "ho sbagliato", "volevo specificare"
        - Portuguese: "desculpa", "quis dizer", "ou melhor", "na verdade", "espera", "quer dizer", "alias", "na verdade nao", "me corrijo", "melhor dizendo", "quero dizer", "espera ai", "me enganei", "deixa eu corrigir"
        - Arabic:     "afwan / عفواً", "aqsid / أقصد", "a3ni / أعني", "bal / بل", "la intazar / لا انتظر", "qasdi / قصدي", "tas-hih / تصحيح", "la bal / لا بل", "aqsid an aqul / اقصد ان اقول", "fi al-waqi3 / في الواقع", "bima3na as-sah / بمعنى أصح", "la la intazir / لا لا انتظر", "al-3afw / العفو", "akhta't / أخطأت"
        - Dutch:      "sorry", "ik bedoel", "nee wacht", "eigenlijk", "of liever", "beter gezegd", "nee", "wacht even", "of eigenlijk", "bedoel ik", "ik vergis me", "laat me corrigeren"
        - Korean:     "joesong / 죄송합니다", "je mal eun / 제 말은", "ani / 아니", "ani yo jab-kan / 아니요 잠깐", "jeong-hwal-hi-neun / 정확히는", "anicul", "dasi malhamyeon", "geuge anira / 그게 아니라", "su-jeong-ham-nida / 수정합니다"
        - Japanese:   "iya / いや", "sumimasen / すみません", "tsumari / つまり", "de wa naku / ではなく", "tei-sei / 訂正します", "janakute / じゃなくて", "nani shiro", "to iu ka", "machigaimashita / 間違えました", "ii naoshimasu / 言い直します"
        - Russian:    "net / нет", "podojdite / подождите", "ya imeyu v vidu / я имею в виду", "tochnee / точнее", "vernee / вернее", "ispravlyus / исправляюсь", "to est / то есть", "eto nepravilno", "oy net / ой нет", "ya oshibsya / я ошибся"
        - Chinese:    "bu dui / 不对", "wo de yi si shi / 我的意思是", "ying gai shi / 应该是", "jiu zheng yi xia / 纠正一下", "bushi / 不是", "wo xiang shuo de shi / 我想说的是", "shuo cuo le / 说错了", "geng zheng / 更正"
        - Turkish:    "hayir bekle / hayır bekle", "yani", "demek istedigim / demek istediğim", "ozur dilerim / özür dilerim", "daha dogrusu", "aslinda", "yani aslinda", "yanlis soyledim / yanlış söyledim", "duzeltiyorum / düzeltiyorum"

        === CRITICAL: INTENT PRESERVATION & WHAT NOT TO DESTROY ===
        You must distinguish between a MISTAKE being retracted and something the speaker GENUINELY MEANT:
        1. GENUINE APOLOGIES: DO NOT delete apologies when expressing courtesy or explaining a situation:
           - "Sorry for the late reply, I was stuck in a call." -> KEEP "Sorry for the late reply..."
           - "Entschuldigung für die Verspätung, der Zug hatte Verspätung." -> KEEP "Entschuldigung für die Verspätung..."
           - "Perdón por la tardanza, ya voy saliendo." -> KEEP "Perdón por la tardanza..."
           - "Pardon pour le dérangement." -> KEEP "Pardon pour le dérangement."
           - "عفواً على التأخير في الرد." -> KEEP "عفواً على التأخير في الرد."
           Only remove apology words when they act solely as a pivot before an immediate factual correction (e.g. "at 10, sorry, 11").

        2. ADDITIONS & AFTERTHOUGHTS: DO NOT treat additive phrases as replacements:
           - "Please send the report. Actually, also attach the financial summary." -> KEEP BOTH! The speaker is adding an item, not canceling the report.
           - "Schick bitte die Rechnung. Eigentlich brauchen wir auch das Protokoll." -> KEEP BOTH!
           - "I need 3 apples. Actually, also 2 bananas." -> KEEP BOTH ("I need 3 apples and also 2 bananas").

        3. CONTRASTS & REAL NEGATIONS:
           - "I don't like coffee, actually I prefer tea." -> Do not remove "actually I prefer tea" or delete the first half. It's a contrastive statement.
           - "Das ist kein Problem." / "No problem." / "No hay problema." -> NEVER strip "no" or "kein".

        4. REASONING ACROSS SENTENCES:
           When a speaker changes their mind and gives a reason across sentences, preserve the reason and apply the resolution cleanly:
           - "Let's meet Tuesday. Wait, Tuesday is a holiday, let's do Wednesday instead." -> "Tuesday is a holiday, so let's meet Wednesday instead." or "Let's meet Wednesday instead, since Tuesday is a holiday."

        MULTILINGUAL CROSS-SENTENCE RESOLUTION EXAMPLES:
          In:  "Can we meet tomorrow at 10? Oh, sorry, I meant 11 a.m."
          Out: "Can we meet tomorrow at 11 a.m.?"

          In:  "Please send the contract to Alice. No wait, Alice is on leave, please send it to Bob."
          Out: "Please send the contract to Bob, Alice is on leave."

          In:  "Konnen wir uns morgen um 10 treffen? Oh sorry, ich meinte 11 Uhr."
          Out: "Konnen wir uns morgen um 11 Uhr treffen?"

          In:  "Hallo konnen wir uns morgen treffen? Nein warte, morgen habe ich Arzttermin, lass uns ubermorgen machen."
          Out: "Lass uns ubermorgen treffen, morgen habe ich einen Arzttermin."

          In:  "Lass uns nach Hamburg fahren. Oder nee, besser gesagt nach Berlin."
          Out: "Lass uns nach Berlin fahren."

          In:  "Ruf bitte David an. Ach Quatsch, nicht David, ruf Michael an."
          Out: "Ruf bitte Michael an."

          In:  "Hola podemos vernos manana a las 3? Perdon, quise decir a las 4."
          Out: "Hola, podemos vernos manana a las 4?"

          In:  "Por favor envia el informe a Carlos. Espera, Carlos esta de vacaciones, enviaselo a Laura."
          Out: "Por favor envia el informe a Laura, Carlos esta de vacaciones."

          In:  "On se voit demain a 14h? Pardon, je voulais dire 15h."
          Out: "On se voit demain a 15h."

          In:  "J'aimerais commander le menu a 25 euros. Non pardon, je me suis trompe, le menu a 30 euros s'il vous plait."
          Out: "J'aimerais commander le menu a 30 euros s'il vous plait."

          In:  "Domani alle 10? Aspetta, intendevo alle 11."
          Out: "Domani alle 11."

          In:  "Ci vediamo alle sei. Anzi no, facciamo alle sette che devo prima finire una cosa."
          Out: "Ci vediamo alle sette che devo prima finire una cosa."

          In:  "Amanha as 10? Ou melhor, as 11."
          Out: "Amanha as 11."

          In:  "Envie o pacote para Sao Paulo. Na verdade, me enganei, envie para o Rio de Janeiro."
          Out: "Envie o pacote para o Rio de Janeiro."

          In:  "Morgen om 10 uur? Nee wacht, 11 uur."
          Out: "Morgen om 11 uur."

          In:  "Stuur het document naar Jan. Wacht even, Jan werkt hier niet meer, stuur het naar Peter."
          Out: "Stuur het document naar Peter, Jan werkt hier niet meer."

          In:  "Yarin saat 10'da? Hayir bekle, 11'de."
          Out: "Yarin saat 11'de."

          In:  "Toplantiyi sali gunu yapalim. Hayir bekle, sali gunu izinliyim, carsamba yapalim."
          Out: "Toplantiyi carsamba gunu yapalim, sali gunu izinliyim."

          In:  "Zavtra v 10? Net, podojdite, v 11."
          Out: "Zavtra v 11."

          In:  "Otpravte otchet Anne. Oy net, ya oshibsya, otpravte ego Maksimu."
          Out: "Otpravte otchet Maksimu."

          In:  "Ashita 10ji ni? Iya, 11ji ni."
          Out: "Ashita 11ji ni."

          In:  "Naeil 10si e? Ani jamkkan, 11si e."
          Out: "Naeil 11si e."

          In:  "Mingtian shidian? Bu dui, shiyidian."
          Out: "Mingtian shiyidian."

          In:  "Qing ba wenjian fa gei Xiao Zhang. Bu dui, wo shuo cuo le, fa gei Xiao Li ba."
          Out: "Qing ba wenjian fa gei Xiao Li ba."

          In:  "hal yumkinuna 3aqd ijtima3 ghadan fi al-3ashira? 3afwan, qasadtu al-hadiya 3ashira."
          Out: "hal yumkinuna 3aqd ijtima3 ghadan fi al-hadiya 3ashira?"

          In:  "Arsil al-malaf ila Khalid. La afwan, akhta't, arsilhu ila Omar."
          Out: "Arsil al-malaf ila Omar."

          In:  "Send 5 copies, make that 10."
          Out: "Send 10 copies."

          In:  "The flight leaves at 6 -- sorry, 7 p.m."
          Out: "The flight leaves at 7 p.m."

        === RULE 2: FILLER WORDS (ALL LANGUAGES) ===
        Silently remove spoken fillers in any language:
        - English:    uh, uhh, um, umm, er, ah, like (filler use), you know, so (sentence-start filler), basically, literally, right (filler)
        - German:     ah, ahm, hm, halt, quasi, sozusagen, na ja, also (sentence-start filler), ne, nicht wahr (filler tag)
        - Spanish:    eh, em, este, o sea (filler), bueno (sentence-start filler), sabes, verdad (filler tag)
        - French:     euh, ben, genre, hein, voila, quoi (sentence-end filler), enfin (filler)
        - Italian:    ehm, cioe (filler), tipo, boh
        - Portuguese: e, tipo, ne, pronto (filler)
        - Arabic:     ya3ni / يعني, ah / آه, im / إم, keda / كده
        - Dutch:      uhm, eh, nou, zeg maar, eigenlijk (filler), gewoon (filler)
        - Korean:     eo / 어, eum / 음, geu / 그, mwo / 뭐, jeo / 저
        - Japanese:   eto / えーと, ano / あの, sono / その, nanka / なんか, ma / まあ
        - Russian:    em / эм, nu / ну, tak / так, vot / вот, korotche / короче, znachit / значит
        - Chinese:    na ge / 那个, jiu shi / 就是, ran hou / 然后, zhe ge / 这个, ni zhi dao / 你知道
        - Turkish:    sey / şey, yani (filler), iste / işte, hani
        - And natural vocal hesitations in any other language.

        === RULE 3: FALSE STARTS & REPETITIONS ===
        Remove aborted sentence restarts and duplicate adjacent words in any language.
        Example: "I want I want to say that" -> "I want to say that"
        Example: "Ich ich habe das gesagt" -> "Ich habe das gesagt"

        === ABSOLUTE CONSTRAINTS ===
        - NEVER translate into English or any other language. Always keep the input language.
        - NEVER invent facts, names, dates, times, numbers, or details not spoken.
        - NEVER change or destroy the core meaning or valid intent.
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
        - Add missing punctuation (commas, periods, question marks) according to the input language's conventions.
        - Capitalise properly according to the rules of the language (e.g. German nouns, Arabic no capitalisation system, Korean/Japanese no case).
        - Preserve vocabulary, tone, and intentional phrasing. Do not translate.
        """

        case .polished:
            return core + """


        === STYLE: POLISHED ===
        After applying Rules 1-3:
        - Rewrite smoothly into clean, professional prose in the transcript's language.
        - Fix grammar, punctuation, and flow while strictly preserving every fact, name, reason, and number.
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
            let result = response.content
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
