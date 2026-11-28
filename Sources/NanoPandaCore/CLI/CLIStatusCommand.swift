import Darwin
import Foundation

enum CLIStatusCommand {
    struct Output {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    static func run(executable: URL, arguments: [String], timeout: Duration = .seconds(35)) -> Output? {
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        for variable in ["GH_DEBUG", "GLAB_DEBUG", "DEBUG", "GIT_TRACE", "GIT_TRACE_CURL", "GIT_CURL_VERBOSE"] {
            environment.removeValue(forKey: variable)
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GLAB_SEND_TELEMETRY"] = "false"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        do { try process.run() }
        catch { return nil }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        defer { for handle in handles { try? handle.close() } }

        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        var streams = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while process.isRunning || descriptors.contains(where: { $0.fd >= 0 }) {
            guard clock.now < deadline, !Task.isCancelled else {
                stop(process)
                return nil
            }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 {
                if errno == EINTR { continue }
                stop(process)
                return nil
            }
            guard ready > 0 else { continue }

            for index in descriptors.indices where descriptors[index].revents != 0 {
                let descriptor = descriptors[index].fd
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 && streams[index].count + count <= 128 * 1024 {
                    streams[index].append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    descriptors[index].fd = -1
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    stop(process)
                    return nil
                }
            }
        }
        guard process.terminationReason == .exit else { return nil }
        return Output(stdout: streams[0], stderr: streams[1], exitCode: process.terminationStatus)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<10 {
            guard process.isRunning else { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
