import Foundation
import CompilerBridge

public enum Language: String, CaseIterable, Sendable {
    case c99 = "C99", cpp11 = "C++11"
    public static func forFileName(_ name: String) -> Language {
        let ext = (name as NSString).pathExtension
        return ext == "C" || ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx"].contains(ext.lowercased()) ? .cpp11 : .c99
    }
}
public struct RunResult: Sendable {
    public let diagnostics: String
    public let output: String
    public let exitCode: UInt32?
    public let failure: String?
    public init(diagnostics: String, output: String, exitCode: UInt32?, failure: String?) {
        self.diagnostics = diagnostics; self.output = output; self.exitCode = exitCode; self.failure = failure
    }
    public var succeeded: Bool { failure == nil && exitCode == 0 }
}
public struct Toolchain: Sendable {
    public let sysroot: URL
    public let frameworks: URL
    public let hostSDK: URL?
    public init(sysroot: URL, frameworks: URL, hostSDK: URL? = nil) {
        self.sysroot = sysroot; self.frameworks = frameworks; self.hostSDK = hostSDK
    }
    public func availability() -> String? {
        guard FileManager.default.fileExists(atPath: sysroot.appendingPathComponent("lib/wasm32-wasi/libc.a").path) else { return "The bundled WASI SDK is missing. Run Mini C/Tools/bootstrap-offline-clang.swift before building." }
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("clang.framework/clang").path) else { return "This compiler supports physical iPhones and Intel simulators. The ARM simulator can test the runtime using bundled .wasm examples." }
        #else
        guard let hostSDK, FileManager.default.fileExists(atPath: hostSDK.appendingPathComponent("bin/clang").path) else { return "Set MINIC_WASI_SDK to a desktop WASI SDK." }
        #endif
        return nil
    }
}
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
public enum PrototypeError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let text): return text } }
}

public final class OfflineCompiler: @unchecked Sendable {
    // LLVM's command globals and ios_system's sessions are not reentrant.
    private static let queue = DispatchQueue(label: "MiniC.offline-clang", qos: .userInitiated)
    private static let compileLock = NSLock()
    public let toolchain: Toolchain
    public init(toolchain: Toolchain) { self.toolchain = toolchain }

    public func run(source: String, language: Language, input: String = "", cancellation: Cancellation = Cancellation(), interactiveInput: ProgramInput? = nil, events: RunEvents = RunEvents(), includeDirectory: URL? = nil) async -> RunResult {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: self.runSynchronously(source: source, language: language, input: input, cancellation: cancellation, interactiveInput: interactiveInput, events: events, includeDirectory: includeDirectory)) }
        }
    }
    public func compile(source: String, language: Language, directory: URL, cancellation: Cancellation = Cancellation(), includeDirectory: URL? = nil, interactiveTerminal: Bool = false) throws -> (URL, String) {
        Self.compileLock.lock(); defer { Self.compileLock.unlock() }
        if let reason = toolchain.availability() { throw PrototypeError.message(reason) }
        guard source.utf8.count <= 256 * 1024, !source.contains("\0") else { throw PrototypeError.message("Source exceeds 256 KiB or contains a NUL byte.") }
        try check(cancellation)
        let cpp = language == .cpp11
        let sourceFile = directory.appendingPathComponent(cpp ? "main.cpp" : "main.c")
        let object = directory.appendingPathComponent("main.o"), module = directory.appendingPathComponent("main.wasm")
        try (source.hasSuffix("\n") ? source : source + "\n").write(to: sourceFile, atomically: true, encoding: .utf8)
        let root = toolchain.sysroot.path
        var args = ["clang", "--target=wasm32-wasi", "--sysroot=\(root)", "-resource-dir", "\(root)/lib/clang/14.0.0", "-x", cpp ? "c++" : "c", cpp ? "-std=c++11" : "-std=c99", "-pedantic-errors", "-Wall", "-Wextra", "-O0", "-fno-color-diagnostics"]
        if cpp { args += ["-fno-exceptions", "-isystem", "\(root)/include/c++/v1"] }
        if let includeDirectory { args += ["-iquote", includeDirectory.path] }
        args += ["-c", sourceFile.path, "-o", object.path]
        let (code, log) = invoke(args, directory: directory)
        guard code == 0, FileManager.default.fileExists(atPath: object.path) else { throw PrototypeError.message(log.isEmpty ? "Clang failed with status \(code)." : log) }
        try check(cancellation)
        var terminalObjects: [String] = []
        if interactiveTerminal {
            // Configure guest libc before main. Flushing the host output stream cannot
            // expose a printf prompt that is still buffered inside guest memory.
            let shim = directory.appendingPathComponent("minic-terminal.c")
            let shimObject = directory.appendingPathComponent("minic-terminal.o")
            try """
            #include <stdio.h>
            __attribute__((constructor)) static void minic_terminal_init(void) {
                setvbuf(stdout, NULL, _IONBF, 0);
                setvbuf(stderr, NULL, _IONBF, 0);
            }
            """.write(to: shim, atomically: true, encoding: .utf8)
            let shimArgs = ["clang", "--target=wasm32-wasi", "--sysroot=\(root)", "-resource-dir", "\(root)/lib/clang/14.0.0", "-std=c99", "-c", shim.path, "-o", shimObject.path]
            let (shimCode, shimLog) = invoke(shimArgs, directory: directory)
            guard shimCode == 0 else { throw PrototypeError.message("Terminal initialization failed: " + shimLog) }
            try check(cancellation)
            terminalObjects = [shimObject.path]
        }
        let lib = "\(root)/lib/wasm32-wasi"
        var link = ["wasm-ld", "--error-limit=10", "--stack-first", "-z", "stack-size=1048576", "--max-memory=67108864", "\(lib)/crt1.o", object.path, "-L", lib]
        link += terminalObjects
        if cpp { link += ["-lc++", "-lc++abi"] }
        link += ["-lc", "\(root)/lib/clang/14.0.0/lib/wasi/libclang_rt.builtins-wasm32.a", "-o", module.path]
        let (linkCode, linkLog) = invoke(link, directory: directory)
        guard linkCode == 0, FileManager.default.fileExists(atPath: module.path) else { throw PrototypeError.message(log + linkLog + "\nLink failed (\(linkCode)).") }
        try check(cancellation)
        guard try Data(contentsOf: module).count <= 16 * 1024 * 1024 else { throw PrototypeError.message("Module exceeds 16 MiB.") }
        return (module, log + linkLog)
    }
    private func invoke(_ args: [String], directory: URL) -> (Int32, String) {
        #if os(macOS)
        if let host = toolchain.hostSDK {
            let process = Process(); process.executableURL = host.appendingPathComponent("bin/\(args[0])")
            process.arguments = Array(args.dropFirst()); process.currentDirectoryURL = directory
            let log = directory.appendingPathComponent("host.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            do {
                let file = try FileHandle(forWritingTo: log); defer { try? file.close() }
                process.standardOutput = file; process.standardError = file
                try process.run(); process.waitUntilExit()
                return (process.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
            } catch { return (-1, String(describing: error)) }
        }
        #endif
        var status: Int32 = -1
        let log = MCInvokeCompiler(toolchain.frameworks.path, args, directory.path, &status)
        return (status, log)
    }
    private func runSynchronously(source: String, language: Language, input: String, cancellation: Cancellation, interactiveInput: ProgramInput?, events: RunEvents, includeDirectory: URL?) -> RunResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniC-Clang-\(UUID().uuidString)")
        var diagnostics = ""
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (module, log) = try compile(source: source, language: language, directory: directory, cancellation: cancellation, includeDirectory: includeDirectory, interactiveTerminal: interactiveInput != nil)
            diagnostics = log
            events.onRunning()
            let result = WasmRunner.run(module: try Data(contentsOf: module), input: input, cancellation: cancellation, interactiveInput: interactiveInput, events: events)
            return RunResult(diagnostics: diagnostics, output: result.output, exitCode: result.exitCode, failure: result.failure)
        } catch { return RunResult(diagnostics: diagnostics, output: "", exitCode: nil, failure: String(describing: error)) }
    }
    private func check(_ cancellation: Cancellation) throws { if cancellation.isCancelled { throw PrototypeError.message("Stopped.") } }
}
