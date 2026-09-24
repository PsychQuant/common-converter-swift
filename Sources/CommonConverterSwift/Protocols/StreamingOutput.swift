import Foundation

/// 串流輸出協定 - 逐段寫入 Markdown，不需要完整文件樹
public protocol StreamingOutput {
    /// 寫入文字
    mutating func write(_ text: String) throws

    /// 寫入一行（含換行符）
    mutating func writeLine(_ text: String) throws

    /// 寫入空行
    mutating func writeBlankLine() throws

    /// 刷新緩衝區
    mutating func flush() throws
}

// MARK: - 預設實作
public extension StreamingOutput {
    mutating func writeLine(_ text: String) throws {
        try write(text + "\n")
    }

    mutating func writeBlankLine() throws {
        try write("\n")
    }
}

// MARK: - FileHandle 輸出（支援 stdout）
public struct FileHandleOutput: StreamingOutput {
    private let fileHandle: FileHandle

    public init(fileHandle: FileHandle = .standardOutput) {
        self.fileHandle = fileHandle
    }

    public init(outputPath: URL) throws {
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath.path) else {
            throw ConversionError.cannotCreateOutput(outputPath.path)
        }
        self.fileHandle = handle
    }

    public func write(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw ConversionError.encodingError
        }
        try fileHandle.write(contentsOf: data)
    }

    /// `fileHandle.synchronize()` (`fsync(2)`) only makes sense for a
    /// regular on-disk file. macdoc#223: when stdout is a pipe (`macdoc
    /// convert ... | cat`), `fsync` returns `EINVAL`, which Foundation
    /// surfaces as a Cocoa "無法儲存檔案" error — even though `write(_:)`
    /// above is already an unbuffered `write(2)`, so there is nothing
    /// buffered to flush in the first place. The same is true for ttys,
    /// sockets and FIFOs: none of them are `S_IFREG`, and none of them
    /// support `fsync`. Skip the sync unless the underlying fd is a regular
    /// file; regular-file writers (`init(outputPath:)`) keep their
    /// durability guarantee.
    public func flush() throws {
        var status = stat()
        if fstat(fileHandle.fileDescriptor, &status) == 0, (status.st_mode & S_IFMT) != S_IFREG {
            // Known non-regular file (pipe/tty/socket/FIFO): nothing to sync.
            return
        }
        // Either a regular file (the common case for `init(outputPath:)`),
        // or `fstat` itself failed — fall through to the original,
        // unconditional behavior rather than silently declaring success on
        // a failure we couldn't fully diagnose. Any genuine problem (e.g. a
        // closed/invalid fd) surfaces through whatever `synchronize()`
        // itself throws, same as before this fix.
        try fileHandle.synchronize()
    }
}

// MARK: - String 輸出（用於測試或小檔案）
public struct StringOutput: StreamingOutput {
    public private(set) var content: String = ""

    public init() {}

    public mutating func write(_ text: String) throws {
        content += text
    }

    public func flush() throws {
        // 無需操作
    }
}
