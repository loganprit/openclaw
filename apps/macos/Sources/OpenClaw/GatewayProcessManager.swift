import Foundation
import Observation

@MainActor
@Observable
final class GatewayProcessManager {
    static let shared = GatewayProcessManager()

    enum Status: Equatable {
        case stopped
        case starting
        case running(details: String?)
        case attachedExisting(details: String?)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case let .running(details):
                if let details, !details.isEmpty { return "Running (\(details))" }
                return "Running"
            case let .attachedExisting(details):
                if let details, !details.isEmpty {
                    return "Using existing gateway (\(details))"
                }
                return "Using existing gateway"
            case let .failed(reason): return "Failed: \(reason)"
            }
        }
    }

    private(set) var status: Status = .stopped {
        didSet { CanvasManager.shared.refreshDebugStatus() }
    }

    private(set) var log: String = ""
    private(set) var environmentStatus: GatewayEnvironmentStatus = .checking
    private(set) var existingGatewayDetails: String?
    private(set) var lastFailureReason: String?
    private var desiredActive = false
    private var environmentRefreshTask: Task<Void, Never>?
    private var lastEnvironmentRefresh: Date?
    private var logRefreshTask: Task<Void, Never>?
    private var childProcess: Process?
    private var childPid: Int32?
    private var childRestartTask: Task<Void, Never>?
    private var childRestartAttempts = 0
    private var childStopInFlight = false
    #if DEBUG
    private var testingConnection: GatewayConnection?
    #endif
    private let logger = Logger(subsystem: "ai.openclaw", category: "gateway.process")

    private let logLimit = 20000 // characters to keep in-memory
    private let environmentRefreshMinInterval: TimeInterval = 30
    private let childRestartBackoffNs: [UInt64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
    ]

    private var connection: GatewayConnection {
        #if DEBUG
        return self.testingConnection ?? .shared
        #else
        return .shared
        #endif
    }

    private var launchMode: AppState.LocalGatewayLaunchMode {
        AppStateStore.shared.localGatewayLaunchMode
    }

    func setActive(_ active: Bool) {
        if CommandResolver.connectionModeIsRemote() {
            self.desiredActive = false
            Task { await self.stopSupervisors() }
            self.status = .stopped
            self.appendLog("[gateway] remote mode active; skipping local gateway\n")
            self.logger.info("gateway process skipped: remote mode active")
            return
        }
        self.logger.debug("gateway active requested active=\(active)")
        self.desiredActive = active
        self.refreshEnvironmentStatus()
        if active {
            self.startIfNeeded()
        } else {
            self.stop()
        }
    }

    func ensureLaunchAgentEnabledIfNeeded() async {
        guard !CommandResolver.connectionModeIsRemote() else { return }
        guard self.launchMode == .launchd else { return }
        if GatewayLaunchAgentManager.isLaunchAgentWriteDisabled() {
            self.appendLog("[gateway] launchd auto-enable skipped (attach-only)\n")
            self.logger.info("gateway launchd auto-enable skipped (disable marker set)")
            return
        }
        let enabled = await GatewayLaunchAgentManager.isLoaded()
        guard !enabled else { return }
        let bundlePath = Bundle.main.bundleURL.path
        let port = GatewayEnvironment.gatewayPort()
        self.appendLog("[gateway] auto-enabling launchd job (\(gatewayLaunchdLabel)) on port \(port)\n")
        let err = await GatewayLaunchAgentManager.set(enabled: true, bundlePath: bundlePath, port: port)
        if let err {
            self.appendLog("[gateway] launchd auto-enable failed: \(err)\n")
        }
    }

    func startIfNeeded() {
        guard self.desiredActive else { return }
        guard !CommandResolver.connectionModeIsRemote() else {
            self.status = .stopped
            return
        }
        if case .starting = self.status { return }
        self.status = .starting
        self.logger.debug("gateway start requested mode=\(self.launchMode.rawValue)")

        Task { [weak self] in
            guard let self else { return }
            switch self.launchMode {
            case .launchd:
                await self.startViaLaunchd()
            case .child:
                await self.startViaChild()
            }
        }
    }

    func stop() {
        self.desiredActive = false
        self.existingGatewayDetails = nil
        self.lastFailureReason = nil
        self.status = .stopped
        self.logger.info("gateway stop requested")
        Task { await self.stopSupervisors() }
    }

    func clearLastFailure() {
        self.lastFailureReason = nil
    }

    func refreshEnvironmentStatus(force: Bool = false) {
        let now = Date()
        if !force {
            if self.environmentRefreshTask != nil { return }
            if let last = self.lastEnvironmentRefresh,
               now.timeIntervalSince(last) < self.environmentRefreshMinInterval
            {
                return
            }
        }
        self.lastEnvironmentRefresh = now
        self.environmentRefreshTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                GatewayEnvironment.check()
            }.value
            await MainActor.run {
                guard let self else { return }
                self.environmentStatus = status
                self.environmentRefreshTask = nil
            }
        }
    }

    func refreshLog() {
        guard self.logRefreshTask == nil else { return }
        let path = GatewayLaunchAgentManager.launchdGatewayLogPath()
        let limit = self.logLimit
        self.logRefreshTask = Task { [weak self] in
            let log = await Task.detached(priority: .utility) {
                Self.readGatewayLog(path: path, limit: limit)
            }.value
            await MainActor.run {
                guard let self else { return }
                if !log.isEmpty {
                    self.log = log
                }
                self.logRefreshTask = nil
            }
        }
    }

    func waitForGatewayReady(timeout: TimeInterval = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !self.desiredActive { return false }
            do {
                _ = try await self.connection.requestRaw(method: .health, timeoutMs: 1500)
                self.clearLastFailure()
                return true
            } catch {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        self.appendLog("[gateway] readiness wait timed out\n")
        self.logger.warning("gateway readiness wait timed out")
        return false
    }

    func clearLog() {
        self.log = ""
        try? FileManager().removeItem(atPath: GatewayLaunchAgentManager.launchdGatewayLogPath())
        self.logger.debug("gateway log cleared")
    }

    func hasRunningChildGateway() -> Bool {
        guard let proc = self.childProcess else { return false }
        return proc.isRunning
    }

    func applyQuitAction(_ action: AppState.ChildGatewayQuitAction) async -> String? {
        switch action {
        case .stopGateway:
            await self.stopChildProcess(reason: "quit")
            return nil
        case .handoffToLaunchd:
            await self.stopChildProcess(reason: "quit handoff")
            if GatewayLaunchAgentManager.isLaunchAgentWriteDisabled() {
                if let markerErr = GatewayLaunchAgentManager.setLaunchAgentWriteDisabled(false) {
                    return markerErr
                }
            }
            let bundlePath = Bundle.main.bundleURL.path
            return await GatewayLaunchAgentManager.set(
                enabled: true,
                bundlePath: bundlePath,
                port: GatewayEnvironment.gatewayPort())
        }
    }

    func setProjectRoot(path: String) {
        CommandResolver.setProjectRoot(path)
    }

    func projectRootPath() -> String {
        CommandResolver.projectRootPath()
    }

    // MARK: - Launchd

    private func startViaLaunchd() async {
        await self.stopChildProcess(reason: "switch to launchd")
        self.childRestartAttempts = 0
        self.childRestartTask?.cancel()
        self.childRestartTask = nil

        self.existingGatewayDetails = nil
        let resolution = await Task.detached(priority: .utility) {
            GatewayEnvironment.resolveGatewayCommand()
        }.value
        await MainActor.run { self.environmentStatus = resolution.status }
        guard resolution.command != nil else {
            await MainActor.run {
                self.status = .failed(resolution.status.message)
            }
            self.logger.error("gateway command resolve failed: \(resolution.status.message)")
            return
        }

        if GatewayLaunchAgentManager.isLaunchAgentWriteDisabled() {
            if let markerErr = GatewayLaunchAgentManager.setLaunchAgentWriteDisabled(false) {
                self.status = .failed(markerErr)
                self.lastFailureReason = markerErr
                self.appendLog("[gateway] failed to clear attach-only marker: \(markerErr)\n")
                return
            }
            self.appendLog("[gateway] cleared attach-only marker for launchd mode\n")
        }

        if await self.attachExistingGatewayIfAvailable() {
            return
        }

        let bundlePath = Bundle.main.bundleURL.path
        let port = GatewayEnvironment.gatewayPort()
        self.appendLog("[gateway] enabling launchd job (\(gatewayLaunchdLabel)) on port \(port)\n")
        self.logger.info("gateway enabling launchd port=\(port)")
        let err = await GatewayLaunchAgentManager.set(enabled: true, bundlePath: bundlePath, port: port)
        if let err {
            self.status = .failed(err)
            self.lastFailureReason = err
            self.logger.error("gateway launchd enable failed: \(err)")
            return
        }

        let ready = await self.waitForGatewayReady(timeout: 6)
        if ready {
            let instance = await PortGuardian.shared.describe(port: port)
            let details = instance.map { "pid \($0.pid)" }
            self.status = .running(details: details)
            self.refreshControlChannelIfNeeded(reason: "gateway started")
            self.refreshLog()
            return
        }

        self.status = .failed("Gateway did not start in time")
        self.lastFailureReason = "launchd start timeout"
        self.logger.warning("gateway start timed out")
    }

    // MARK: - Child mode

    private func startViaChild() async {
        self.existingGatewayDetails = nil
        self.childRestartTask?.cancel()
        self.childRestartTask = nil

        let bundlePath = Bundle.main.bundleURL.path
        _ = await GatewayLaunchAgentManager.set(
            enabled: false,
            bundlePath: bundlePath,
            port: GatewayEnvironment.gatewayPort())

        if let process = self.childProcess, process.isRunning {
            let details = self.childPid.map { "pid \($0)" } ?? "pid unknown"
            self.status = .running(details: details)
            return
        }

        let port = GatewayEnvironment.gatewayPort()
        if let instance = await PortGuardian.shared.describe(port: port) {
            let runningChildPid = self.childPid
            if runningChildPid == nil || instance.pid != runningChildPid {
                let detail = self.describe(instance: instance)
                let reason =
                    "Port \(port) is already in use by \(detail). Child mode requires an app-owned process."
                self.status = .failed(reason)
                self.lastFailureReason = reason
                self.appendLog("[gateway] child mode conflict: \(reason)\n")
                return
            }
        }

        await self.spawnChildGateway()
    }

    private func spawnChildGateway() async {
        let resolution = await Task.detached(priority: .utility) {
            GatewayEnvironment.resolveGatewayCommand()
        }.value
        await MainActor.run { self.environmentStatus = resolution.status }
        guard let command = resolution.command, !command.isEmpty else {
            self.status = .failed(resolution.status.message)
            self.lastFailureReason = resolution.status.message
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CommandResolver.preferredPaths().joined(separator: ":")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let logURL = URL(fileURLWithPath: GatewayLaunchAgentManager.launchdGatewayLogPath())
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.readSafely(upToCount: 64 * 1024)
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? logHandle?.write(contentsOf: data)
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Task { @MainActor in
                    self?.appendLog(text)
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.readSafely(upToCount: 64 * 1024)
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? logHandle?.write(contentsOf: data)
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Task { @MainActor in
                    self?.appendLog(text)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()
            Task { @MainActor in
                await self?.handleChildExit(terminationStatus: proc.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            self.status = .failed("Failed to start child gateway: \(error.localizedDescription)")
            self.lastFailureReason = error.localizedDescription
            self.childProcess = nil
            self.childPid = nil
            try? logHandle?.close()
            return
        }

        self.childProcess = process
        self.childPid = process.processIdentifier
        self.childStopInFlight = false
        self.appendLog("[gateway] spawned child process pid \(process.processIdentifier)\n")
        self.logger.info("gateway child spawned pid=\(process.processIdentifier)")

        if await self.waitForGatewayReady(timeout: 8) {
            self.childRestartAttempts = 0
            let details = "pid \(process.processIdentifier)"
            self.clearLastFailure()
            self.status = .running(details: details)
            self.refreshControlChannelIfNeeded(reason: "gateway child started")
            self.refreshLog()
            return
        }

        self.status = .failed("Gateway child did not become ready in time")
        self.lastFailureReason = "child start timeout"
        await self.stopChildProcess(reason: "child readiness timeout")
    }

    private func handleChildExit(terminationStatus: Int32) async {
        let pid = self.childPid ?? -1
        self.childProcess = nil
        self.childPid = nil
        Task { await PortGuardian.shared.removeRecord(pid: pid) }

        if self.childStopInFlight {
            self.childStopInFlight = false
            self.appendLog("[gateway] child exited (expected)\n")
            return
        }

        let reason = "child exited with status \(terminationStatus)"
        self.appendLog("[gateway] \(reason)\n")
        self.logger.warning("gateway \(reason)")

        guard self.desiredActive, self.launchMode == .child else {
            self.status = .stopped
            return
        }

        if self.childRestartAttempts >= self.childRestartBackoffNs.count {
            self.status = .failed("Gateway child crashed repeatedly; restart attempts exhausted.")
            self.lastFailureReason = reason
            return
        }

        let delayNs = self.childRestartBackoffNs[self.childRestartAttempts]
        self.childRestartAttempts += 1
        let attempt = self.childRestartAttempts
        self.status = .starting
        self.appendLog("[gateway] restarting child (attempt \(attempt))\n")
        self.childRestartTask?.cancel()
        self.childRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            await MainActor.run {
                guard let self, self.desiredActive, self.launchMode == .child else { return }
                Task { await self.startViaChild() }
            }
        }
    }

    private func stopChildProcess(reason: String) async {
        self.childRestartTask?.cancel()
        self.childRestartTask = nil
        guard let process = self.childProcess else { return }
        self.childStopInFlight = true
        self.appendLog("[gateway] stopping child (\(reason))\n")

        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                _ = await ShellExecutor.run(
                    command: ["kill", "-KILL", "\(process.processIdentifier)"],
                    cwd: nil,
                    env: nil,
                    timeout: 2)
            }
        }
    }

    private func stopSupervisors() async {
        await self.stopChildProcess(reason: "stop")
        let bundlePath = Bundle.main.bundleURL.path
        _ = await GatewayLaunchAgentManager.set(
            enabled: false,
            bundlePath: bundlePath,
            port: GatewayEnvironment.gatewayPort())
    }

    // MARK: - Internals

    /// Attempt to connect to an already-running gateway on the configured port.
    /// If successful, mark status as attached and skip spawning a new process.
    private func attachExistingGatewayIfAvailable() async -> Bool {
        let port = GatewayEnvironment.gatewayPort()
        let instance = await PortGuardian.shared.describe(port: port)
        let instanceText = instance.map { self.describe(instance: $0) }
        let hasListener = instance != nil

        let attemptAttach = {
            try await self.connection.requestRaw(method: .health, timeoutMs: 2000)
        }

        for attempt in 0..<(hasListener ? 3 : 1) {
            do {
                let data = try await attemptAttach()
                let snap = decodeHealthSnapshot(from: data)
                let details = self.describe(details: instanceText, port: port, snap: snap)
                self.existingGatewayDetails = details
                self.clearLastFailure()
                self.status = .attachedExisting(details: details)
                self.appendLog("[gateway] using existing instance: \(details)\n")
                self.logger.info("gateway using existing instance details=\(details)")
                self.refreshControlChannelIfNeeded(reason: "attach existing")
                self.refreshLog()
                return true
            } catch {
                if attempt < 2, hasListener {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                if hasListener {
                    let reason = self.describeAttachFailure(error, port: port, instance: instance)
                    self.existingGatewayDetails = instanceText
                    self.status = .failed(reason)
                    self.lastFailureReason = reason
                    self.appendLog("[gateway] existing listener on port \(port) but attach failed: \(reason)\n")
                    self.logger.warning("gateway attach failed reason=\(reason)")
                    return true
                }

                self.existingGatewayDetails = nil
                return false
            }
        }

        self.existingGatewayDetails = nil
        return false
    }

    private func describe(details instance: String?, port: Int, snap: HealthSnapshot?) -> String {
        let instanceText = instance ?? "pid unknown"
        if let snap {
            let order = snap.channelOrder ?? Array(snap.channels.keys)
            let linkId = order.first(where: { snap.channels[$0]?.linked == true })
                ?? order.first(where: { snap.channels[$0]?.linked != nil })
            guard let linkId else {
                return "port \(port), health probe succeeded, \(instanceText)"
            }
            let linked = snap.channels[linkId]?.linked ?? false
            let authAge = snap.channels[linkId]?.authAgeMs.flatMap(msToAge) ?? "unknown age"
            let label =
                snap.channelLabels?[linkId] ??
                linkId.capitalized
            let linkText = linked ? "linked" : "not linked"
            return "port \(port), \(label) \(linkText), auth \(authAge), \(instanceText)"
        }
        return "port \(port), health probe succeeded, \(instanceText)"
    }

    private func describe(instance: PortGuardian.Descriptor) -> String {
        let path = instance.executablePath ?? "path unknown"
        return "pid \(instance.pid) \(instance.command) @ \(path)"
    }

    private func describeAttachFailure(_ error: Error, port: Int, instance: PortGuardian.Descriptor?) -> String {
        let ns = error as NSError
        let message = ns.localizedDescription.isEmpty ? "unknown error" : ns.localizedDescription
        let lower = message.lowercased()
        if self.isGatewayAuthFailure(error) {
            return """
            Gateway on port \(port) rejected auth. Set gateway.auth.token to match the running gateway \
            (or clear it on the gateway) and retry.
            """
        }
        if lower.contains("protocol mismatch") {
            return "Gateway on port \(port) is incompatible (protocol mismatch). Update the app/gateway."
        }
        if lower.contains("unexpected response") || lower.contains("invalid response") {
            return "Port \(port) returned non-gateway data; another process is using it."
        }
        if let instance {
            let instanceText = self.describe(instance: instance)
            return "Gateway listener found on port \(port) (\(instanceText)) but health check failed: \(message)"
        }
        return "Gateway listener found on port \(port) but health check failed: \(message)"
    }

    private func isGatewayAuthFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .dataNotAllowed {
            return true
        }
        let ns = error as NSError
        if ns.domain == "Gateway", ns.code == 1008 { return true }
        let lower = ns.localizedDescription.lowercased()
        return lower.contains("unauthorized") || lower.contains("auth")
    }

    private func appendLog(_ chunk: String) {
        self.log.append(chunk)
        if self.log.count > self.logLimit {
            self.log = String(self.log.suffix(self.logLimit))
        }
    }

    private func refreshControlChannelIfNeeded(reason: String) {
        switch ControlChannel.shared.state {
        case .connected, .connecting:
            return
        case .disconnected, .degraded:
            break
        }
        self.appendLog("[gateway] refreshing control channel (\(reason))\n")
        self.logger.debug("gateway control channel refresh reason=\(reason)")
        Task { await ControlChannel.shared.configure() }
    }

    private nonisolated static func readGatewayLog(path: String, limit: Int) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

#if DEBUG
extension GatewayProcessManager {
    func setTestingConnection(_ connection: GatewayConnection?) {
        self.testingConnection = connection
    }

    func setTestingDesiredActive(_ active: Bool) {
        self.desiredActive = active
    }

    func setTestingLastFailureReason(_ reason: String?) {
        self.lastFailureReason = reason
    }
}
#endif
