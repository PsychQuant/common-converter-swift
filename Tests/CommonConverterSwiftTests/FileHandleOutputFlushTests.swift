import XCTest
@testable import CommonConverterSwift

/// PsychQuant/macdoc#223: `FileHandleOutput.flush()` called
/// `fileHandle.synchronize()`（`fsync(2)`）unconditionally. `fsync` only
/// makes sense for a regular on-disk file; on a pipe it returns `EINVAL`,
/// which Foundation surfaces as a Cocoa "無法儲存檔案" (couldn't be saved)
/// error. Every `convertToStdout` call ends with a `flush()`, so any
/// `macdoc convert` route piped to another process (`macdoc convert ... |
/// cat`) exited 1 even though the content had already been written
/// correctly — pipes, ttys, sockets and FIFOs are not `S_IFREG`, so none of
/// them should be fsync'd.
final class FileHandleOutputFlushTests: XCTestCase {

    /// The exact regression from #223: writing to stdout when it is a real
    /// OS pipe (not just an in-memory buffer) must not throw on `flush()`.
    func testFlushOnAPipeDoesNotThrow() throws {
        let pipe = Pipe()

        // Drain concurrently so `write(_:)` below can never block on a full
        // pipe buffer waiting for a reader that only starts after we're
        // done writing.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reader = Thread {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        reader.start()

        let output = FileHandleOutput(fileHandle: pipe.fileHandleForWriting)
        try output.write("hello pipe\n")
        // This is the line #223 is about: on unfixed code this throws
        // ConversionError-wrapped EINVAL from fsync(2) on a pipe fd.
        XCTAssertNoThrow(try output.flush(), "flush() must not fsync a pipe")

        try pipe.fileHandleForWriting.close()

        // Give the reader a bounded moment to finish, then check content
        // made it through untouched — the fix must not skip writing.
        let deadline = Date().addingTimeInterval(2)
        while box.data.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(String(data: box.data, encoding: .utf8), "hello pipe\n")
    }

    /// Writing to a regular file must keep the durability guarantee
    /// `flush()` originally existed for — the fix must not turn `flush()`
    /// into a no-op across the board, only skip fsync on non-regular files.
    func testFlushOnARegularFileStillSucceedsAndPersistsContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("common-converter-swift-flush-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("out.txt")
        let output = try FileHandleOutput(outputPath: fileURL)
        try output.write("hello file\n")
        XCTAssertNoThrow(try output.flush())

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(content, "hello file\n")
    }

    /// `flush()` on stdout redirected to a tty-like character device (here:
    /// `/dev/null`, a character special device) must also not fsync — the
    /// fix should key off "is this a regular file", not "is this literally
    /// a pipe".
    func testFlushOnACharacterDeviceDoesNotThrow() throws {
        guard let handle = FileHandle(forWritingAtPath: "/dev/null") else {
            throw XCTSkip("/dev/null not writable in this sandbox")
        }
        let output = FileHandleOutput(fileHandle: handle)
        try output.write("ignored\n")
        XCTAssertNoThrow(try output.flush())
    }
}
