import Foundation
@_spi(Fuzzing) import WasmKit
import WasmKitWASI
@_spi(WASIPlatform) import WASI

private final class Limits: ResourceLimiter {
    func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= 64 * 1024 * 1024 }
    func limitTableGrowth(to desired: Int) throws -> Bool { desired <= 10_000 }
}

/// A fresh store per run. Guests receive only buffered stdio, no host directory or network.
public enum WasmRunner {
    public static func run(module data: Data, input: String = "", cancellation: Cancellation = Cancellation(), fuel: UInt64 = 5_000_000, interactiveInput: ProgramInput? = nil, events: RunEvents = RunEvents()) -> RunResult {
        let output = BufferedStream(cancellation: cancellation, events: events)
        var inputEvents = events
        inputEvents.onWaitingForInput = { waiting in
            if waiting { output.flushOutput() }
            events.onWaitingForInput(waiting)
        }
        let stdin = BufferedStream(input: Array(input.utf8), cancellation: cancellation, interactiveInput: interactiveInput, events: inputEvents)
        do {
            guard data.count <= 16 * 1024 * 1024, input.utf8.count <= 64 * 1024 else { throw PrototypeError.message("Module or input exceeds prototype limits.") }
            if cancellation.isCancelled { throw PrototypeError.message("Stopped.") }
            let module = try parseWasm(bytes: Array(data))
            let engine = Engine(configuration: EngineConfiguration(memoryBoundsChecking: .software, fuelMetering: true))
            let store = Store(engine: engine)
            store.resourceLimiter = Limits(); store.fuel = Fuel(remaining: fuel)
            let wasi = try WASIBridgeToHost(args: ["main"], fileSystem: .host().withStdio(stdin: stdin, stdout: output, stderr: output))
            defer { try? wasi.close() }
            var imports = Imports(); wasi.link(to: &imports, store: store)
            let instance = try module.instantiate(store: store, imports: imports)
            let code = try wasi.start(instance)
            if cancellation.isCancelled { throw PrototypeError.message("Stopped.") }
            return RunResult(diagnostics: "", output: output.text, exitCode: code, failure: nil)
        } catch {
            return RunResult(diagnostics: "", output: output.text, exitCode: nil, failure: cancellation.isCancelled ? "Stopped." : String(describing: error))
        }
    }
}

// The bridge executes this stream on the same worker as the store. It owns no OS fd.
private final class BufferedStream: WASIFile, @unchecked Sendable {
    private var bytes: [UInt8]
    private var position = 0
    private var lastOutput = Date.distantPast
    private let input: Bool
    private let cancellation: Cancellation
    private let interactiveInput: ProgramInput?
    private let events: RunEvents
    var text: String { String(decoding: bytes, as: UTF8.self) }
    init(input: [UInt8]? = nil, cancellation: Cancellation, interactiveInput: ProgramInput? = nil, events: RunEvents = RunEvents()) {
        self.interactiveInput = interactiveInput; self.events = events
        bytes = input ?? []; self.input = input != nil; self.cancellation = cancellation
    }
    func attributes() throws -> WASIAbi.Filestat { .init(dev: 0, ino: 0, filetype: .CHARACTER_DEVICE, nlink: 0, size: UInt64(bytes.count), atim: 0, mtim: 0, ctim: 0) }
    func fileType() throws -> WASIAbi.FileType { .CHARACTER_DEVICE }
    func status() throws -> WASIAbi.Fdflags { [] }
    func fdStat() throws -> WASIAbi.FdStat { .init(fsFileType: .CHARACTER_DEVICE, fsFlags: [], fsRightsBase: input ? [.FD_READ] : [.FD_WRITE], fsRightsInheriting: []) }
    func setTimes(atim: WASIAbi.Timestamp, mtim: WASIAbi.Timestamp, fstFlags: WASIAbi.FstFlags) throws { throw WASIAbi.Errno.ENOTSUP }
    func advise(offset: WASIAbi.FileSize, length: WASIAbi.FileSize, advice: WASIAbi.Advice) throws {}
    func close() throws {}
    func setFdStatFlags(_ flags: WASIAbi.Fdflags) throws { if !flags.isEmpty { throw WASIAbi.Errno.ENOTSUP } }
    func setFilestatSize(_ size: WASIAbi.FileSize) throws { throw WASIAbi.Errno.ENOTSUP }
    func sync() throws {}
    func datasync() throws {}
    func tell() throws -> WASIAbi.FileSize { throw WASIAbi.Errno.ESPIPE }
    func seek(offset: WASIAbi.FileDelta, whence: WASIAbi.Whence) throws -> WASIAbi.FileSize { throw WASIAbi.Errno.ESPIPE }
    func pwrite(vectored buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size { throw WASIAbi.Errno.ESPIPE }
    func pread(into buffers: GuestBuffers, offset: WASIAbi.FileSize) throws -> WASIAbi.Size { throw WASIAbi.Errno.ESPIPE }
    func write(vectored buffers: GuestBuffers) throws -> WASIAbi.Size {
        guard !input else { throw WASIAbi.Errno.EBADF }
        if cancellation.isCancelled { throw PrototypeError.message("Stopped.") }
        var count = 0
        for index in 0..<buffers.count {
            try buffers.withHostBuffer(at: index) { buffer in
                guard buffer.count <= 256 * 1024 - bytes.count else { throw PrototypeError.message("Output exceeded 256 KiB.") }
                bytes.append(contentsOf: buffer); count += buffer.count; return buffer.count
            }
        }
        if Date().timeIntervalSince(lastOutput) >= 0.03 {
            lastOutput = Date(); flushOutput()
        }
        return UInt32(count)
    }
    func flushOutput() {
        // A guest write can split a UTF-8 scalar. Wait for the next write before publishing it.
        if let complete = String(bytes: bytes, encoding: .utf8) { events.onOutput(complete) }
    }
    func read(into buffers: GuestBuffers) throws -> WASIAbi.Size {
        guard input else { throw WASIAbi.Errno.EBADF }
        if cancellation.isCancelled { throw PrototypeError.message("Stopped.") }
        var count = 0
        for index in 0..<buffers.count {
            try buffers.withHostBuffer(at: index) { buffer in
                if let interactiveInput, count == 0 {
                    let chunk = try interactiveInput.read(maxCount: buffer.count, cancellation: cancellation, waiting: events.onWaitingForInput)
                    bytes = chunk; position = 0
                }
                let size = min(buffer.count, bytes.count - position)
                if size > 0 { bytes.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[position..<(position + size)])) } }
                position += size; count += size; return size
            }
        }
        return UInt32(count)
    }
}
