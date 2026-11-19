//
//  AudioCaptureEngine.swift
//  Whistral
//
//  Captures microphone audio and delivers 16 kHz mono Float32 chunks to the
//  transcription controller, plus a smoothed level (0...1) for the HUD meters.
//

import AVFoundation
import Foundation
import os.log

final class AudioCaptureEngine: NSObject {

    static let targetSampleRate: Double = 16000
    static let targetChannelCount: AVAudioChannelCount = 1

    private let engine = AVAudioEngine()

    /// Called from a realtime audio thread with converted 16 kHz mono samples.
    var onAudio: (([Float32]) -> Void)?
    /// Called from the audio thread with a smoothed 0...1 input level.
    var onLevel: ((Float) -> Void)?

    private var isCapturing = false
    private var workItem: DispatchWorkItem?

    func start() throws {
        guard !isCapturing else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.conversionFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.conversionFailed
        }

        let tapFormat = inputFormat
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    var capturing: Bool { isCapturing }

    // MARK: - Conversion

    private func handleBuffer(_ buffer: AVAudioPCMBuffer,
                              converter: AVAudioConverter,
                              targetFormat: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Input level for the waveform meters (hardware-rate mono average).
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        var sampleCount = 0
        for ch in 0..<min(1, channelCount) {
            let ptr = channelData[ch]
            for i in 0..<frames {
                sum += ptr[i] * ptr[i]
            }
            sampleCount += frames
        }
        let rms = sqrt(sum / Float(max(sampleCount, 1)))
        let level = min(1, pow(rms * 6.0, 0.6))
        onLevel?(level)

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var conversionError: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            os_log("Audio conversion error: %{public}@", type: .error, String(describing: conversionError))
            return
        }

        guard status != .error, let outData = outBuffer.floatChannelData else { return }
        let outFrames = Int(outBuffer.frameLength)
        guard outFrames > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: outData[0], count: outFrames))
        onAudio?(samples)
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone found. Connect a microphone and try again."
        case .conversionFailed:
            return "Whistral could not set up audio processing for this microphone."
        }
    }
}
