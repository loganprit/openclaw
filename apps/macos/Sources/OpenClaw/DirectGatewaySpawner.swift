import Darwin
import Foundation

@MainActor
final class DirectGatewaySpawner {
    static let shared = DirectGatewaySpawner()

    enum Event {
        case started(pid: Int32, restartAttempt: Int)
        case restartScheduled(attempt: Int, delaySeconds: Double, reason: String)
        case gaveUp(reason: String)
        case stopped
    }

    var onLog: ((String) -> Void)?
    var onEvent: ((Event) -> Void)?

    private(set) var isRunning = false
    private(set) var processID: Int32?

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var restartTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var lastCommand: [String]?
    private var lastEnv: [String: String]?
    private var stoppingRequested = false

    private let maxRestartAttempts = 5
    private let logger = Logger(subsystem: "ai.openclaw", category: "gateway.direct")

    func spawn(command: [String], env: [String: String]? = nil) async throws {
        guard !command.isEmpty else {
            throw NSError(
                domain: "DirectGatewaySpawner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Gateway command is empty"])
        }

        if self.process != nil {
            await self.stop(clearRememberedCommand: false)
        }

        self.restartTask?.cancel()
        self.restartTask = nil
        self.stoppingRequested = false
        self.restartAttempts = 0
        self.lastCommand = command
        self.lastEnv = env
        try self.startProcess(command: command, env: env, restartAttempt: 0)
    }

    func restart() async throws {
        guard let command = self.lastCommand else {
            throw NSError(
                domain: "DirectGatewaySpawner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No gateway command available to restart"])
        }
        let env = self.lastEnv
        await self.stop(clearRememberedCommand: false)
        try await self.spawn(command: command, env: env)
    }

    func stop() async {
        await self.stop(clearRememberedCommand: true)
    }

    func stopForApplicationTermination() {
        self.stoppingRequested = true
        self.restartTask?.cancel()
        self.restartTask = nil
        self.lastCommand = nil
        self.lastEnv = nil
        self.restartAttempts = 0

        guard let process else {
            self.cleanupPipes()
            self.processID = nil
            self.isRunning = false
            return
        }

        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        self.cleanupPipes()
        self.process = nil
        self.processID = nil
        self.isRunning = false
        self.stoppingRequested = false
    }

    private func stop(clearRememberedCommand: Bool) async {
        self.stoppingRequested = true
        self.restartTask?.cancel()
        self.restartTask = nil

        if clearRememberedCommand {
            self.lastCommand = nil
            self.lastEnv = nil
            self.restartAttempts = 0
        }

        guard let process else {
            self.cleanupPipes()
            self.processID = nil
            self.isRunning = false
            self.stoppingRequested = false
            if clearRememberedCommand {
                self.onEvent?(.stopped)
            }
            return
        }

        if process.isRunning {
            process.terminate()
            let exited = await self.waitForExit(process, timeout: 1.5)
            if !exited {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = await self.waitForExit(process, timeout: 0.8)
            }
        }

        self.cleanupPipes()
        self.process = nil
        self.processID = nil
        self.isRunning = false
        self.stoppingRequested = false

        if clearRememberedCommand {
            self.onEvent?(.stopped)
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !process.isRunning
    }

    private func startProcess(command: [String], env: [String: String]?, restartAttempt: Int) throws {
        guard let executable = command.first else {
            throw NSError(
                domain: "DirectGatewaySpawner",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Gateway executable is missing"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = self.mergedEnvironment(additional: env)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        self.attachOutputHandler(to: stdout)
        self.attachOutputHandler(to: stderr)

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(process)
            }
        }

        do {
            try process.run()
        } catch {
            Self.detachOutputHandler(stdout)
            Self.detachOutputHandler(stderr)
            throw NSError(
                domain: "DirectGatewaySpawner",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to start gateway process: \(error.localizedDescription)",
                ])
        }

        self.process = process
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
        self.processID = process.processIdentifier
        self.isRunning = true
        self.onEvent?(.started(pid: process.processIdentifier, restartAttempt: restartAttempt))
        self.logger.info("direct gateway started pid=\(process.processIdentifier)")
    }

    private func attachOutputHandler(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readable in
            let data = readable.readSafely(upToCount: 64 * 1024)
            guard !data.isEmpty else {
                Self.detachOutputHandler(readable)
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task { @MainActor in
                self?.onLog?(text)
            }
        }
    }

    private static func detachOutputHandler(_ handle: FileHandle) {
        if handle.readabilityHandler != nil {
            handle.readabilityHandler = nil
        }
        try? handle.close()
    }

    private func cleanupPipes() {
        if let stdoutHandle {
            Self.detachOutputHandler(stdoutHandle)
            self.stdoutHandle = nil
        }
        if let stderrHandle {
            Self.detachOutputHandler(stderrHandle)
            self.stderrHandle = nil
        }
    }

    private func handleTermination(_ process: Process) {
        let pid = process.processIdentifier
        let status = process.terminationStatus
        let reason = process.terminationReason
        self.cleanupPipes()
        if self.process?.processIdentifier == pid {
            self.process = nil
        }
        self.processID = nil
        self.isRunning = false

        if self.stoppingRequested {
            self.stoppingRequested = false
            self.logger.info("direct gateway stopped pid=\(pid) status=\(status)")
            return
        }

        self.logger.warning("direct gateway exited pid=\(pid) status=\(status)")
        self.scheduleRestart(exitStatus: status, terminationReason: reason, startError: nil)
    }

    private func scheduleRestart(
        exitStatus: Int32?,
        terminationReason: Process.TerminationReason?,
        startError: Error?)
    {
        guard self.lastCommand != nil else {
            self.onEvent?(.gaveUp(reason: "Direct gateway command missing; restart aborted."))
            return
        }

        guard self.restartAttempts < self.maxRestartAttempts else {
            let reason = self.describeRestartCause(
                exitStatus: exitStatus,
                terminationReason: terminationReason,
                startError: startError)
            self.onEvent?(.gaveUp(reason: "Direct gateway crashed repeatedly (\(reason))."))
            return
        }

        self.restartAttempts += 1
        let attempt = self.restartAttempts
        let delaySeconds = self.backoffDelaySeconds(attempt: attempt)
        let reason = self.describeRestartCause(
            exitStatus: exitStatus,
            terminationReason: terminationReason,
            startError: startError)
        self.onEvent?(.restartScheduled(attempt: attempt, delaySeconds: delaySeconds, reason: reason))

        self.restartTask?.cancel()
        self.restartTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.performScheduledRestart()
        }
    }

    private func performScheduledRestart() async {
        guard !self.stoppingRequested else { return }
        guard let command = self.lastCommand else {
            self.onEvent?(.gaveUp(reason: "Direct gateway command missing; restart aborted."))
            return
        }

        do {
            try self.startProcess(command: command, env: self.lastEnv, restartAttempt: self.restartAttempts)
        } catch {
            self.scheduleRestart(exitStatus: nil, terminationReason: nil, startError: error)
        }
    }

    private func mergedEnvironment(additional: [String: String]?) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        if let additional {
            merged.merge(additional) { _, new in new }
        }
        return merged
    }

    private func backoffDelaySeconds(attempt: Int) -> Double {
        let delay = pow(2.0, Double(max(attempt - 1, 0)))
        return min(delay, 16.0)
    }

    private func describeRestartCause(
        exitStatus: Int32?,
        terminationReason: Process.TerminationReason?,
        startError: Error?) -> String
    {
        if let startError {
            return startError.localizedDescription
        }
        let statusText = exitStatus.map { "exit \($0)" } ?? "unknown exit"
        let reasonText: String
        switch terminationReason {
        case .none:
            reasonText = "reason unknown"
        case .some(.exit):
            reasonText = "normal exit"
        case .some(.uncaughtSignal):
            reasonText = "signal"
        @unknown default:
            reasonText = "unknown reason"
        }
        return "\(statusText), \(reasonText)"
    }
}
