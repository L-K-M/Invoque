import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns one bounded helper invocation. Query text is an argument, never shell code.
struct NumbatEvaluator: Sendable {
    static let timeout: TimeInterval = 2
    private static let pollInterval: TimeInterval = 0.01
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
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // NSTask's run-loop bookkeeping must stay on one OS thread.
                // An async task can resume on a different thread after each poll.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try run(expression, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func run(_ expression: String, cancellation: Cancellation) throws -> String? {
        try cancellation.check()
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
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure.timedOut
            }
            // Deliver NSTask's termination notifications on its launch thread.
            RunLoop.current.run(until: Date().addingTimeInterval(Self.pollInterval))
        }
        try cancellation.check()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.failed
        }
        // Read available bytes, not an EOF-dependent Foundation read. The helper
        // has exited, so its entire bounded answer is already in the pipe.
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw Failure.failed }
        var buffer = [UInt8](repeating: 0, count: Self.maxOutputBytes + 1)
        var count: Int
        repeat { count = read(descriptor, &buffer, buffer.count) } while count == -1 && errno == EINTR
        if count == -1, errno == EAGAIN { return nil }
        guard count >= 0, count <= Self.maxOutputBytes,
              let text = String(bytes: buffer.prefix(count), encoding: .utf8) else { throw Failure.failed }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.failed
        }
        return result.isEmpty ? nil : result
    }

    /// Cancellation crosses from Swift tasks to the synchronous process owner.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }
}
