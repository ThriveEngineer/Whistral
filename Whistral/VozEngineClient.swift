//
//  VozEngineClient.swift
//  Whistral
//
//  On-device speech engine backed by Desert Ant Labs' Voz model (Parakeet
//  TDT 0.6B v3, Core ML on the Neural Engine), via the official
//  desert-ant-core Swift package. Unlike the Python sidecar, this runs
//  in-process: no venv, no pipes — just the Core ML models, which the SDK
//  downloads from Hugging Face on first use.
//
//  Streaming uses the SDK's LiveTranscriber: microphone chunks are appended
//  as they arrive and transcript updates arrive on an AsyncStream, mapped
//  onto the same EngineEvent set the sidecar produces so
//  TranscriptionController needs no Voz-specific code.
//

import Foundation
import ModelStore // for DownloadProgress.completedBytes / totalBytes
import Voz

final class VozEngineClient: SpeechEngine {

    /// Model ID used in the settings picker. The "voz:" prefix routes to this
    /// engine in AppModel.activeEngine.
    static let modelID = "voz:desert-ant-labs/voz"
    static let displayName = "Desert Ant — Voz (Neural Engine)"

    weak var delegate: SpeechEngineDelegate?

    private var voz: Voz?
    private var live: LiveTranscriber?
    private var updateTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var sessionToken = 0
    private var cancelled = false

    // MARK: - SpeechEngine

    /// Idempotent: repeated load calls while a download/init is in flight or
    /// after the model is ready are no-ops.
    func load(modelID: String) {
        if voz != nil || loadTask != nil { return }
        loadTask = Task {
            emit(.modelState(.loading))
            do {
                if !Voz.isDownloaded() {
                    _ = try await Voz.download { progress in
                        self.emit(.modelState(.downloadingModel(
                            received: Int(progress.completedBytes),
                            total: Int(progress.totalBytes)
                        )))
                    }
                }
                self.voz = try await Voz()
                emit(.modelState(.ready(model: Self.displayName)))
            } catch {
                emit(.modelState(.error("Voz failed to load: \(error.localizedDescription)")))
            }
            loadTask = nil
        }
    }

    func start(delayMs: Int, sessionToken: Int) {
        guard let voz else {
            emit(.modelState(.error("Voz model is not loaded yet.")))
            return
        }
        self.sessionToken = sessionToken
        self.cancelled = false
        let live = voz.liveTranscriber()
        self.live = live

        emit(.sessionStarted)
        let token = sessionToken
        updateTask = Task { [weak self] in
            for await update in live.updates {
                guard let self, !self.cancelled else { continue }
                if update.isFinal {
                    emitOnMain(.final(text: update.text, token: token))
                } else {
                    emitOnMain(.partial(index: 0,
                                        segmentText: update.tentativeText,
                                        text: update.text))
                }
            }
        }
    }

    func sendAudio(samples: [Float32]) {
        guard let live = self.live else { return }
        let floats = samples.map { Float($0) }
        Task { await live.append(floats, sampleRate: AudioCaptureEngine.targetSampleRate) }
    }

    func stop() {
        let live = self.live
        // finish() makes the SDK emit a final LiveUpdate (isFinal == true)
        // on the updates stream, which the update task turns into .final.
        Task { await live?.finish() }
    }

    func cancel() {
        cancelled = true
        let live = self.live
        self.live = nil
        let token = sessionToken
        Task { await live?.finish() }
        emit(.cancelled(token: token))
    }

    // MARK: - Event emission (always on the main queue, like the sidecar)

    private func emit(_ event: EngineEvent) {
        emitOnMain(event)
    }

    private func emitOnMain(_ event: EngineEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.speechEngine(self, didReceiveEvent: event)
        }
    }
}
