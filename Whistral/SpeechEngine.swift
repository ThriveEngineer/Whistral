//
//  SpeechEngine.swift
//  Whistral
//
//  Common interface for the speech-to-text backends the app can route
//  between: the Python/MLX sidecar (Voxtral) and the on-device Core ML
//  engine (Voz). TranscriptionController talks only to this protocol;
//  AppModel picks the active engine from the selected model ID.
//

import Foundation

/// Events any speech engine can emit. Mirrors the sidecar's JSON event set.
enum EngineEvent {
    case ready
    case modelState(EngineState)
    case sessionStarted
    case partial(index: Int, segmentText: String, text: String)
    case segment(index: Int, text: String)
    case final(text: String, token: Int?)
    case cancelled(token: Int?)
    case fileTranscript(path: String, text: String)
    case error(message: String)
}

protocol SpeechEngineDelegate: AnyObject {
    func speechEngine(_ engine: any SpeechEngine, didReceiveEvent event: EngineEvent)
    func speechEngine(_ engine: any SpeechEngine, didLog message: String)
}

/// A loadable, streamable speech-to-text engine.
///
/// Session model: `load` a model, then `start` a session, stream audio with
/// `sendAudio`, and end with `stop` (final transcript via `.final`) or
/// `cancel` (`.cancelled`). `delayMs` is a latency/accuracy trade-off hint;
/// engines that don't support it may ignore it.
protocol SpeechEngine: AnyObject {
    var delegate: SpeechEngineDelegate? { get set }
    func load(modelID: String)
    func start(delayMs: Int, sessionToken: Int)
    func stop()
    func cancel()
    func sendAudio(samples: [Float32])
}
