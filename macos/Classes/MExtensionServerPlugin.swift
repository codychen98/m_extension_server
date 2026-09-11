import Cocoa
import FlutterMacOS

public class MExtensionServerPlugin: NSObject, FlutterPlugin {

    private static let maxLogLines = 2000

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "m_extension_server",
            binaryMessenger: registrar.messenger)
        let instance = MExtensionServerPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private var javaProcess: Process?
    private var outputPipe: Pipe?
    private let logLock = NSLock()
    private var logLines: [String] = []
    private var droppedLines = 0
    private var pendingLine = ""

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startServer":
            guard let args = call.arguments as? [String: Any],
            let port = args["port"] as? Int else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing or invalid 'port' argument",
                    details: nil))
                return
            }
            guard let serverJarPath = args["serverJarPath"] as? String,
            !serverJarPath.isEmpty else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing 'serverJarPath' argument; required on macOS",
                    details: nil))
                return
            }
            let jvmPath = args["jvmPath"] as? String
            let jvmArgs = args["jvmArgs"] as? [String] ?? []
            startServer(port: port,
                jvmPath: jvmPath,
                serverJarPath: serverJarPath,
                jvmArgs: jvmArgs,
                result: result)

        case "stopServer":
            stopServer(result: result)

        case "drainServerLogs":
            drainServerLogs(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startServer(port: Int,
    jvmPath: String?,
    serverJarPath: String,
    jvmArgs: [String],
    result: @escaping FlutterResult) {
        terminateJavaProcess()

        let resolvedJava = resolveJavaExecutable(from: jvmPath)
        let javaExe = resolvedJava.path

        guard javaBinaryExists(at: javaExe) else {
            print("m_extension_server: failed to resolve Java executable. Checked: \(resolvedJava.checked)")
            result(FlutterError(
                code: "START_ERROR",
                message: "Failed to locate a Java executable",
                details: resolvedJava.checked))
            return
        }

        let process = configuredProcess(javaExe: javaExe,
            serverJarPath: serverJarPath,
            port: port,
            jvmArgs: jvmArgs)
        print("m_extension_server: launching Java from \(javaExe)")

        do {
            try process.run()
            javaProcess = process
            result("Server started on port \(port)")
        } catch {
            clearOutputPipe()
            let detailedError = buildLaunchErrorMessage(error, javaExe: javaExe)
            print("m_extension_server: launch failed for \(javaExe): \(detailedError)")
            result(FlutterError(
                code: "START_ERROR",
                message: detailedError,
                details: javaExe))
        }
    }

    private func stopServer(result: @escaping FlutterResult) {
        guard let process = javaProcess, process.isRunning else {
            clearOutputPipe()
            javaProcess = nil
            result("Server was not running")
            return
        }

        process.terminate()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            process.waitUntilExit()
            self?.clearOutputPipe()
            self?.javaProcess = nil
            DispatchQueue.main.async {
                result("Server stopped")
            }
        }
    }

    private func drainServerLogs(result: @escaping FlutterResult) {
        logLock.lock()
        let drained = logLines
        let dropped = droppedLines
        logLines = []
        droppedLines = 0
        logLock.unlock()

        var out: [String] = []
        if dropped > 0 {
            out.append("[m_extension_server] dropped \(dropped) lines")
        }
        out.append(contentsOf: drained)
        result(out)
    }

    private func appendLogChunk(_ chunk: String) {
        logLock.lock()
        defer { logLock.unlock() }

        pendingLine += chunk
        while let range = pendingLine.range(of: "\n") {
            var line = String(pendingLine[..<range.lowerBound])
            pendingLine = String(pendingLine[range.upperBound...])
            if line.hasSuffix("\r") {
                line = String(line.dropLast())
            }
            while logLines.count >= Self.maxLogLines {
                logLines.removeFirst()
                droppedLines += 1
            }
            logLines.append(line)
        }
    }

    private func flushPendingLogLine() {
        logLock.lock()
        defer { logLock.unlock() }
        guard !pendingLine.isEmpty else { return }
        var line = pendingLine
        pendingLine = ""
        if line.hasSuffix("\r") {
            line = String(line.dropLast())
        }
        while logLines.count >= Self.maxLogLines {
            logLines.removeFirst()
            droppedLines += 1
        }
        logLines.append(line)
    }

    private func clearOutputPipe() {
        if let handle = outputPipe?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        outputPipe = nil
        flushPendingLogLine()
    }

    private func terminateJavaProcess() {
        guard let process = javaProcess, process.isRunning else {
            clearOutputPipe()
            javaProcess = nil
            return
        }
        process.terminate()
        process.waitUntilExit()
        clearOutputPipe()
        javaProcess = nil
    }

    deinit {
        terminateJavaProcess()
    }

    private func configuredProcess(javaExe: String,
    serverJarPath: String,
    port: Int,
    jvmArgs: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: javaExe)
        process.arguments = jvmArgs + ["-jar", serverJarPath, String(port)]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.flushPendingLogLine()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            self?.appendLogChunk(text)
        }
        outputPipe = pipe
        return process
    }

    private func resolveJavaExecutable(from jvmPath: String?) -> (path: String, checked: [String]) {
        var candidates: [String] = []

        if let rawPath = normalizedInputPath(jvmPath), !rawPath.isEmpty {
            appendJavaCandidates(for: rawPath, to: &candidates)
            if let executable = candidates.first(where: { javaBinaryExists(at: $0) }) {
                return (executable, candidates)
            }
            return (candidates.first ?? rawPath, candidates)
        }

        if let javaHome = normalizedInputPath(ProcessInfo.processInfo.environment["JAVA_HOME"]),
        !javaHome.isEmpty {
            appendJavaCandidates(for: javaHome, to: &candidates)
            if let executable = candidates.first(where: { javaBinaryExists(at: $0) }) {
                return (executable, candidates)
            }
        }

        appendCandidate("/usr/bin/java", to: &candidates)
        if let executable = candidates.first(where: { javaBinaryExists(at: $0) }) {
            return (executable, candidates)
        }

        return (candidates.first ?? "/usr/bin/java", candidates)
    }

    private func appendJavaCandidates(for rawPath: String, to candidates: inout [String]) {
        let expandedPath    = (rawPath as NSString).expandingTildeInPath
        let standardizedPath = (expandedPath as NSString).standardizingPath
        guard !standardizedPath.isEmpty else { return }

        appendCandidate(standardizedPath, to: &candidates)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardizedPath,
            isDirectory: &isDirectory)

        if exists && isDirectory.boolValue {
            appendCandidate(
                (standardizedPath as NSString).appendingPathComponent("bin/java"),
                to: &candidates)
            appendCandidate(
                (standardizedPath as NSString).appendingPathComponent("jre/bin/java"),
                to: &candidates)

        } else if URL(fileURLWithPath: standardizedPath).lastPathComponent == "java" {
            if let deduped = deduplicatedAdjacentPathComponents(in: standardizedPath) {
                appendCandidate(deduped, to: &candidates)
            }

            let binDir   = (standardizedPath as NSString).deletingLastPathComponent
            let javaHome = (binDir as NSString).deletingLastPathComponent
            appendCandidate(
                (javaHome as NSString).appendingPathComponent("bin/java"),
                to: &candidates)

            if let dedupedHome = deduplicatedAdjacentPathComponents(in: javaHome) {
                appendCandidate(
                    (dedupedHome as NSString).appendingPathComponent("bin/java"),
                    to: &candidates)
            }

        } else {
            appendCandidate(
                (standardizedPath as NSString).appendingPathComponent("bin/java"),
                to: &candidates)
            appendCandidate(
                (standardizedPath as NSString).appendingPathComponent("jre/bin/java"),
                to: &candidates)
        }

        if let deduped = deduplicatedAdjacentPathComponents(in: standardizedPath) {
            appendCandidate(deduped, to: &candidates)
            appendCandidate(
                (deduped as NSString).appendingPathComponent("bin/java"),
                to: &candidates)
            appendCandidate(
                (deduped as NSString).appendingPathComponent("jre/bin/java"),
                to: &candidates)
        }
    }

    private func appendCandidate(_ path: String, to candidates: inout [String]) {
        guard !path.isEmpty, !candidates.contains(path) else { return }
        candidates.append(path)
    }

    private func javaBinaryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private func buildLaunchErrorMessage(_ error: Error, javaExe: String) -> String {
        let nsError = error as NSError
        var message = "Failed to launch Java server: \(nsError.localizedDescription)"

        if javaBinaryExists(at: javaExe),
        nsError.domain == NSCocoaErrorDomain,
        nsError.code == NSFileNoSuchFileError {
            message += " The Java binary exists, so macOS likely rejected execution"
            + " of the child process or one of its dependent libraries."
            + " In a sandboxed macOS app, spawning an arbitrary downloaded"
            + " JVM commonly fails this way."
            + " Use an embedded helper tool signed for sandbox inheritance,"
            + " or run the host app without App Sandbox."
        }

        message += " [domain=\(nsError.domain) code=\(nsError.code)]"
        return message
    }

    private func normalizedInputPath(_ rawPath: String?) -> String? {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
        !path.isEmpty else { return nil }

        if (path.hasPrefix("\"") && path.hasSuffix("\""))
        || (path.hasPrefix("'") && path.hasSuffix("'")) {
            path.removeFirst()
            path.removeLast()
        }

        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }

        return path
    }

    private func deduplicatedAdjacentPathComponents(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard components.count > 1 else { return nil }

        var deduplicated: [String] = []
        var didChange = false

        for component in components {
            if let last = deduplicated.last, last == component, component != "/" {
                didChange = true
                continue
            }
            deduplicated.append(component)
        }

        return didChange ? NSString.path(withComponents: deduplicated) : nil
    }
}
