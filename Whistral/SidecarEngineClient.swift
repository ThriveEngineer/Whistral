//
//  SidecarEngineClient.swift
//  Whistral
//
//  Spawns and talks to the bundled Python engine (whistral_engine.py), which
//  runs the Voxtral Mini 4B Realtime model via MLX on the Apple GPU.
//
//  One-time engine bootstrap (first launch): creates a Python virtual
//  environment in Application Support and pip-installs the engine
//  dependencies listed in Resources/Engine/requirements.txt.
//

import AppKit
import Combine
import Foundation

enum EngineState: Equatable {
    case notInstalled          // venv missing, needs bootstrap
    case bootstrapping         // creating venv / pip installing
    case downloadingModel(received: Int, total: Int)
    case loading               // weights loading into memory
    case ready(model: String)
    case error(String)
    case stopped
}

protocol SidecarEngineClientDelegate: AnyObject {
    func engineClient(_ client: SidecarEngineClient, didReceiveEvent event: EngineEvent)
    func engineClient(_ client: SidecarEngineClient, didLog message: String)
}

enum EngineEvent {
    case ready
    case modelState(EngineState)
    case sessionStarted
    case partial(index: Int, segmentText: String, text: String)
    case segment(index: Int, text: String)
    case final(text: String)
    case cancelled
    case fileTranscript(path: String, text: String)
    case error(message: String)
}

final class SidecarEngineClient: NSObject {

    weak var delegate: SidecarEngineClientDelegate?

    // MARK: - Paths

    /// Support directory shared by engine venv and model cache.
    static var appSupportURL: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whistral", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var venvPythonURL: URL {
        appSupportURL.appendingPathComponent("venv/bin/python")
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private let writeLock = NSLock()
    private var stdoutBuffer = Data()
    private let stdoutQueue = DispatchQueue(label: "app.whistral.engine.stdout")
    private var isEngineAlive = false

    // MARK: - Public API

    /// Makes sure the venv exists, then starts the engine process.
    /// Completion arrives on the main queue with nil for success.
    func ensureRunning() {
        if isEngineAlive { return }

        let pythonURL = Self.venvPythonURL
        guard FileManager.default.fileExists(atPath: pythonURL.path) else {
            bootstrap { [weak self] error in
                guard let self else { return }
                if let error {
                    self.delegate?.engineClient(self, didReceiveEvent: .modelState(.error(error)))
                } else {
                    self.startEngine()
                }
            }
            return
        }
        startEngine()
    }

    /// One-time dependency install: python3 -m venv + pip install -r requirements.txt
    private func bootstrap(completion: @escaping (String?) -> Void) {
        delegate?.engineClient(self, didReceiveEvent: .modelState(.notInstalled))
        delegate?.engineClient(self, didLog: "Preparing the speech engine (first run only)…")

        let support = Self.appSupportURL
        let systemPython = "/usr/bin/python3"

        guard FileManager.default.fileExists(atPath: systemPython) else {
            completion("Python 3 is required. Install Python (developer.apple.com or python.org) and relaunch Whistral.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

                let venv = Process()
                venv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                venv.arguments = ["-m", "venv", support.appendingPathComponent("venv").path]
                let envOut = Pipe()
                let envErr = Pipe()
                venv.standardOutput = envOut
                venv.standardError = envErr
                try venv.run()
                venv.waitUntilExit()
                guard venv.terminationStatus == 0 else {
                    let msg = String(data: envErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    completion("Could not create the engine environment: \(msg.suffix(300))")
                    return
                }

                guard let requirements = Bundle.main.url(forResource: "requirements", withExtension: "txt")
                else {
                    // Fall back to installing the package directly.
                    let pip = Process()
                    pip.executableURL = Self.venvPythonURL
                    pip.arguments = ["-m", "pip", "install", "--quiet", "voxmlx"]
                    pip.standardOutput = Pipe()
                    pip.standardError = Pipe()
                    try pip.run()
                    pip.waitUntilExit()
                    guard pip.terminationStatus == 0 else {
                        completion("Could not install engine packages. Check your internet connection and relaunch.")
                        return
                    }
                    completion(nil)
                    return
                }

                self.delegate?.engineClient(self, didLog: "Installing engine packages…")
                let pip = Process()
                pip.executableURL = Self.venvPythonURL
                pip.arguments = ["-m", "pip", "install", "--quiet", "-r", requirements.path]
                let pipErr = Pipe()
                pip.standardOutput = Pipe()
                pip.standardError = pipErr
                try pip.run()
                pip.waitUntilExit()
                guard pip.terminationStatus == 0 else {
                    let msg = String(data: pipErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    completion("Engine package install failed: \(msg.suffix(300))")
                    return
                }
                completion(nil)
            } catch {
                completion("Engine setup failed: \(error.localizedDescription)")
            }
        }
    }

    private func startEngine() {
        guard let engineScript = Self.engineScriptURL() else {
            delegate?.engineClient(self, didReceiveEvent: .modelState(.error("Engine script missing from app bundle.")))
            return
        }

        let python = Self.venvPythonURL.path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [
            "-u",
            engineScript.path,
        ]
        proc.standardInput = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.delegate?.engineClient(self, didLog: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        do {
            try proc.run()
        } catch {
            delegate?.engineClient(self, didReceiveEvent: .modelState(.error("Could not start the engine: \(error.localizedDescription)")))
            return
        }

        process = proc
        stdinHandle = proc.standardInput as? FileHandle
        isEngineAlive = true

        proc.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.isEngineAlive = false
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                if self.delegate != nil {
                    self.delegate?.engineClient(self, didReceiveEvent: .modelState(
                        status == 0
                            ? .stopped
                            : .error("The speech engine exited unexpectedly (code \(status)).")
                    ))
                }
            }
        }

        // Read stdout line-by-line (JSON events).
        stdoutQueue.async { [weak self, stdoutPipe] in
            let handle = stdoutPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                // Split complete lines
                while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: Data(lineData), encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                       !line.isEmpty,
                       let event = Self.parseEvent(line) {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.delegate?.engineClient(self, didReceiveEvent: event)
                        }
                    }
                }
            }
        }

        delegate?.engineClient(self, didReceiveEvent: .ready)
    }

    static func engineScriptURL(for bundle: Bundle = .main) -> URL? {
        if let direct = bundle.url(forResource: "whistral_engine", withExtension: "py") {
            return direct
        }
        for subdir in ["Engine", "Resources/Engine"] {
            if let url = bundle.url(forResource: "whistral_engine", withExtension: "py", subdirectory: subdir) {
                return url
            }
        }
        return nil
    }

    // MARK: - Framing

    private func writeFrame(type: UInt8, payload: Data) {
        guard let handle = stdinHandle, isEngineAlive else { return }
        var frame = Data(capacity: payload.count + 5)
        var length = UInt32(payload.count + 1).littleEndian
        withUnsafeMutableBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type)
        frame.append(payload)
        writeLock.lock()
        handle.write(frame)
        writeLock.unlock()
    }

    private func writeCommand(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        writeFrame(type: 0x01, payload: data)
    }

    func sendAudio(samples: [Float32]) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        writeFrame(type: 0x02, payload: data)
    }

    // MARK: - Commands

    func load(modelID: String, temperature: Float = 0.0) {
        writeCommand(["cmd": "load", "model": modelID, "temperature": temperature])
    }

    func start(delayMs: Int) {
        writeCommand(["cmd": "start", "delayMs": delayMs])
    }

    func stop() {
        writeCommand(["cmd": "stop"])
    }

    func cancel() {
        writeCommand(["cmd": "cancel"])
    }

    func transcribeFile(_ path: String) {
        writeCommand(["cmd": "transcribe", "path": path])
    }

    func quit() {
        writeCommand(["cmd": "quit"])
    }

    func terminate() {
        quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.process?.terminate()
        }
        stdinHandle = nil
        process = nil
        isEngineAlive = false
    }

    // MARK: - Event parsing

    static func parseEvent(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "ready":
            return .ready
        case "modelState":
            let state = obj["state"] as? String ?? ""
            switch state {
            case "loading":
                return .modelState(.loading)
            case "downloading":
                return .modelState(.downloadingModel(received: obj["received"] as? Int ?? 0,
                                                     total: obj["total"] as? Int ?? 1))
            case "ready":
                return .modelState(.ready(model: obj["model"] as? String ?? modelDefaultName))
            case "error":
                return .modelState(.error(obj["message"] as? String ?? "Unknown model error"))
            default:
                return nil
            }
        case "sessionStarted":
            return .sessionStarted
        case "partial":
            return .partial(index: obj["index"] as? Int ?? 0,
                            segmentText: obj["segmentText"] as? String ?? "",
                            text: obj["text"] as? String ?? "")
        case "segment":
            return .segment(index: obj["index"] as? Int ?? 0, text: obj["text"] as? String ?? "")
        case "final":
            return .final(text: obj["text"] as? String ?? "")
        case "cancelled":
            return .cancelled
        case "fileTranscript":
            return .fileTranscript(path: obj["path"] as? String ?? "", text: obj["text"] as? String ?? "")
        case "error":
            return .error(message: obj["message"] as? String ?? "Unknown error")
        case "log":
            return nil // logs go through the delegate separately if needed
        default:
            return nil
        }
    }

    static let modelDefaultName = "Voxtral Mini 4B Realtime"
}
