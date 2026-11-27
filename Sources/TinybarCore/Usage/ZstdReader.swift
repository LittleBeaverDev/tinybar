import Foundation

/// Streams decoded bytes without a shell or an output-size limit.
enum ZstdReader {
    enum Failure: Error {
        case missingExecutable
        case failed(Int32)
        case launch(Error)
    }

    static func executable() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("zstd").path
        let paths = [bundled, "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].compactMap { $0 }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/zstd" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    static func forEachLine(url: URL, until: Int64? = nil, executable: URL? = executable(),
                            _ body: (UnsafeRawBufferPointer) -> Void) throws -> Int64 {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.missingExecutable }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-dc", "--", url.path]
        process.standardOutput = pipe
        // Discard diagnostics rather than letting a full stderr pipe block the decoder.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.launch(error) }
        pipe.fileHandleForWriting.closeFile()
        defer { pipe.fileHandleForReading.closeFile() }
        let result: Result<Int64, Error>
        do { result = .success(try JSONLReader.readLines(fd: pipe.fileHandleForReading.fileDescriptor, from: 0, until: until, drain: true, body)) }
        catch { result = .failure(error) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.failed(process.terminationStatus) }
        return try result.get()
    }
}
