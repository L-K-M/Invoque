import Foundation
import os

/// One invocation's captured output: `console.*`, `invoque.log` and
/// `invoque.notify` all append here so the caller can show the lines next to
/// the result.
///
/// Thread-safe via a lock: lines are appended on the invocation's JS queue
/// but a timeout snapshot can be taken from a different queue.
final class CommandLog {

    private let lock = NSLock()
    private var lines: [String] = []
    private let logger = Logger(subsystem: "com.invoque.Invoque", category: "command")

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        // Script output can contain anything the command saw, so it stays at
        // the default private redaction in the system log; the buffer holds
        // the plaintext for display in-app.
        logger.debug("\(line)")
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
