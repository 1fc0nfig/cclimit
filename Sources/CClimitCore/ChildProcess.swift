import Foundation

/// Runs a short-lived tool (`security`, a login shell, `claude auth logout`) with a hard
/// deadline. A child that hangs, or a grandchild that keeps the pipe open, must not hold a
/// thread or a spinner forever: past the deadline the child gets SIGTERM, then SIGKILL.
public enum ChildProcess {
    public struct Result: Sendable {
        public let status: Int32
        public let output: Data
        public let timedOut: Bool
    }

    /// Blocks the calling thread until the child exits or the deadline passes. Call it off
    /// the main thread. Throws only when the executable cannot start.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        timeout: TimeInterval
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        let output = LockedBox(Data())
        let drained = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                output.mutate { $0.append(chunk) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        if let stdin, let input {
            // Short inputs only (a command line): they fit the pipe buffer, so this never blocks.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            stop(process, exited: exited)
        }
        // The output ends at EOF. A grandchild that holds the pipe open gets one second.
        _ = drained.wait(timeout: .now() + 1)
        stdout.fileHandleForReading.readabilityHandler = nil
        // terminationStatus raises while the child runs: an unkillable child reads as -1.
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: status, output: output.value, timedOut: timedOut)
    }

    /// SIGTERM, a two-second grace, then SIGKILL. Returns once the child is gone.
    static func stop(_ process: Process, exited: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
    }
}
