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
    case final(text: String, token: Int?)
    case cancelled(token: Int?)
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
    // stdinHandle/isEngineAlive are owned by the write queue: every mutation
    // happens on writeQueue with writeLock held (see writeFrame/startEngine/
    // terminate/terminationHandler), so the realtime tap thread never touches
    // them and cannot race the main-thread terminate().
    private var stdinHandle: FileHandle?
    private let writeLock = NSLock()
    private let stdoutQueue = DispatchQueue(label: "app.whistral.engine.stdout")
    private let writeQueue = DispatchQueue(label: "app.whistral.engine.stdin")
    private var isEngineAlive = false
    private var isBootstrapping = false
    private var isAppTerminating = false
    private var crashRestartCount = 0

    override init() {
        super.init()
        // A dead engine's pipe read-end must surface as EPIPE on write(), never
        // as SIGPIPE (which would kill the process) and never as the ObjC
        // NSFileHandleOperationException that Swift cannot catch. Whistral has
        // no other raw socket/pipe writes, so ignoring SIGPIPE process-wide is
        // safe; exec'd children reset ignored signals to their defaults.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Public API

    /// Makes sure the venv exists, then starts the engine process.
    func ensureRunning() {
        writeLock.lock()
        let alive = isEngineAlive
        writeLock.unlock()
        if alive || isBootstrapping { return }

        let pythonURL = Self.venvPythonURL
        guard FileManager.default.fileExists(atPath: pythonURL.path) else {
            bootstrap { [weak self] error in
                // The bootstrap can finish on a background queue; hop back to
                // main so subsequent state mutations and delegate calls are safe.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBootstrapping = false
                    if let error {
                        self.delegate?.engineClient(self, didReceiveEvent: .modelState(.error(error)))
                    } else {
                        self.startEngine()
                    }
                }
            }
            return
        }
        startEngine()
    }

    /// One-time dependency install: python3 -m venv + pip install -r requirements.txt
    private func bootstrap(completion: @escaping (String?) -> Void) {
        guard !isBootstrapping else { return }
        isBootstrapping = true
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
            isBootstrapping = false
            delegate?.engineClient(self, didReceiveEvent: .modelState(.error("Could not start the engine: \(error.localizedDescription)")))
            return
        }
        // Note: crashRestartCount is deliberately NOT reset here. Resetting at
        // spawn would make the ≤3 restart cap unreachable (crash → restart →
        // reset → crash …). It is cleared only once the engine proves healthy
        // by reaching .modelState(.ready), see the stdout event handler below.

        process = proc
        // standardInput was assigned an NSPipe; grab its writing end. The
        // assignments are funneled through the write queue (the state's owner,
        // see writeFrame); FIFO order lands them before any frame write this
        // spawn enqueues afterwards.
        if (proc.standardInput as? Pipe)?.fileHandleForWriting == nil {
            delegate?.engineClient(self, didReceiveEvent: .modelState(.error("Could not open the engine's input pipe.")))
            return
        }
        let inputPipe = proc.standardInput as? Pipe
        writeQueue.sync {
            self.stdinHandle = inputPipe?.fileHandleForWriting
            self.isEngineAlive = true
        }

        proc.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // The handler runs on an arbitrary queue: pipe state belongs to
            // the write queue, so invalidate there instead of mutating from
            // this thread (which raced main-thread terminate() and the
            // writer before).
            self.writeQueue.async {
                self.writeLock.lock()
                self.isEngineAlive = false
                self.stdinHandle = nil
                self.writeLock.unlock()
            }
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard self.delegate != nil else { return }
                if self.isAppTerminating {
                    self.delegate?.engineClient(self, didReceiveEvent: .modelState(
                        status == 0 ? .stopped : .error("The speech engine exited (code \(status)).")
                    ))
                    return
                }
                if status == 0 {
                    self.delegate?.engineClient(self, didReceiveEvent: .modelState(.stopped))
                } else {
                    // Restart automatically, with a limited backoff so a
                    // persistently failing engine can't loop forever.
                    self.crashRestartCount += 1
                    if self.crashRestartCount <= 3 {
                        self.delegate?.engineClient(self, didLog: "Engine exited unexpectedly (code \(status)); restarting…")
                        self.delegate?.engineClient(self, didReceiveEvent: .modelState(.stopped))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.ensureRunning()
                        }
                    } else {
                        self.delegate?.engineClient(self, didReceiveEvent: .modelState(
                            .error("The speech engine keeps crashing (code \(status)). Try reinstalling it from Settings → Engine.")
                        ))
                    }
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
                            // The engine proving healthy clears the crash
                            // backoff for the next crash cycle.
                            if case .modelState(.ready) = event {
                                self.crashRestartCount = 0
                            }
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
        // Called from the realtime audio tap thread for audio frames: never
        // block there, and never touch pipe state from this thread. Everything
        // — the death check and the write — happens on the serial write queue,
        // so frames queued while the engine dies are handled by the write
        // path's EPIPE handling instead of racing a concurrent invalidation.
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.performWrite(type: type, payload: payload)
        }
    }

    /// Performs one framed write. Runs on writeQueue only.
    /// SIGPIPE is ignored process-wide (see init) and no FileHandle.write is
    /// used, so a reader-less pipe surfaces here as errno EPIPE — logged and
    /// absorbed by marking the engine dead — instead of as the uncatchable
    /// ObjC NSFileHandleOperationException (Swift `catch` can't intercept it)
    /// or a process-killing signal.
    private func performWrite(type: UInt8, payload: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard let handle = stdinHandle, isEngineAlive else {
            logDroppedFrameOnce()
            return
        }

        var frame = Data(capacity: payload.count + 5)
        var length = UInt32(payload.count + 1).littleEndian
        withUnsafeMutableBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type)
        frame.append(payload)

        var offset = 0
        let written = frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            while offset < raw.count {
                let n = Darwin.write(handle.fileDescriptor,
                                     raw.baseAddress!.advanced(by: offset),
                                     raw.count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false // EPIPE or an equivalent fatal pipe error
                }
                offset += n
            }
            return true
        }
        if !written {
            // Engine is gone mid-queue: mark dead so remaining queued frames
            // drop without individual syscalls, and stay silent about it beyond
            // the one-time log (terminationHandler reports the death itself).
            isEngineAlive = false
            stdinHandle = nil
            logDroppedFrameOnce()
        }
    }

    /// One-time notification that frames are being dropped. writeLock held.
    private func logDroppedFrameOnce() {
        if !dropWarningShown {
            dropWarningShown = true
            delegate?.engineClient(self, didLog: "Engine is not running; dropped a frame.")
        }
    }

    private var dropWarningShown = false

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

    func start(delayMs: Int, sessionToken: Int = 0) {
        writeCommand(["cmd": "start", "delayMs": delayMs, "token": sessionToken])
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
        isAppTerminating = true
        quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.process?.terminate()
        }
        // Pipe state is owned by the write queue. FIFO order sends the quit
        // command (enqueued by quit() above) before this invalidation runs.
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock()
            self.stdinHandle = nil
            self.isEngineAlive = false
            self.writeLock.unlock()
        }
        process = nil
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
            return .final(text: obj["text"] as? String ?? "", token: obj["token"] as? Int)
        case "cancelled":
            return .cancelled(token: obj["token"] as? Int)
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
