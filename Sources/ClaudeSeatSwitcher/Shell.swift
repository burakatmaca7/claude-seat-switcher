import Foundation

/// Runs a command and returns its output. No shell is involved: arguments are passed as-is.
///
/// Robust against misbehaving children: a timeout sends SIGTERM, then SIGKILL after one second;
/// output is collected until EOF but never waited on for more than a second after the process
/// exits (a grandchild that keeps the pipe open cannot block the caller).
enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Writing to a pipe whose reader has exited must not kill the app.
    static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil, input: String? = nil,
                    timeout: TimeInterval = 20) -> Result {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        process.standardOutput = out
        process.standardError = err

        let collector = Collector()
        let eof = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            eof.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    eof.leave()
                } else {
                    collector.append(d, toStdout: isOut)
                }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if let input {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // Give the readers a moment to drain; never block on a pipe held open by a grandchild.
        if eof.wait(timeout: .now() + 1) == .timedOut {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        let (o, e) = collector.snapshot()
        return Result(status: process.isRunning ? -1 : process.terminationStatus,
                      stdout: String(decoding: o, as: UTF8.self),
                      stderr: String(decoding: e, as: UTF8.self))
    }

    /// Runs `run` off the calling thread, for use from the main actor.
    static func runAsync(_ executable: String, _ arguments: [String],
                         environment: [String: String]? = nil, input: String? = nil,
                         timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: run(executable, arguments, environment: environment,
                                           input: input, timeout: timeout))
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func append(_ d: Data, toStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if toStdout { out.append(d) } else { err.append(d) }
        }
        func snapshot() -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            return (out, err)
        }
    }
}
