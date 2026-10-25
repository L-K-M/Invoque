import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns one bounded helper invocation. Query text is an argument, never shell code.
struct NumbatEvaluator: Sendable {
    static let timeout: TimeInterval = 2
    private static let pollNanoseconds: UInt64 = 10_000_000
    private static let maxOutputBytes = 4096

    private let executableURL: URL?
    private let timeLimit: TimeInterval

    init(executableURL: URL? = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/invoque-numbat"),
         timeLimit: TimeInterval = Self.timeout) {
        self.executableURL = executableURL
        self.timeLimit = timeLimit
    }

    enum Failure: LocalizedError {
        case unavailable
        case timedOut
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The bundled Numbat helper is missing. Reinstall Invoque."
            case .timedOut: return "Calculation exceeded the time limit."
            case .failed: return "Numbat could not evaluate this calculation."
            }
        }
    }

    func evaluate(_ expression: String) async throws -> String? {
        // Process launch and pipe reads stay off the caller's actor.
        let work = Task.detached(priority: .userInitiated) {
            try await run(expression)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func run(_ expression: String) async throws -> String? {
        try Task.checkCancellation()
        guard let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw Failure.unavailable
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [expression]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Close our copy so EOF follows the helper's exit.
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                // Numbat can recurse indefinitely; a hard stop also handles ignored SIGTERM.
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure.timedOut
            }
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.failed
        }
        // The owned helper emits at most one bounded numeric result.
        let data = try pipe.fileHandleForReading.read(upToCount: Self.maxOutputBytes + 1) ?? Data()
        guard data.count <= Self.maxOutputBytes,
              let text = String(data: data, encoding: .utf8) else { throw Failure.failed }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.failed
        }
        return result.isEmpty ? nil : result
    }
}
