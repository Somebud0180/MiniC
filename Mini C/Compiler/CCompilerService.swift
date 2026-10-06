import Foundation
import MiniClang

/// The editor and terminal use the same bundled Clang → WebAssembly engine as the lab.
@MainActor
public final class CCompilerService {
    public static let shared = CCompilerService()
    public init() {}

    public func compileAndRun(source: String, fileName: String, input: ProgramInput, fileDirectory: URL?,
                              cancellation: Cancellation, events: RunEvents) async -> RunResult {
        let language = Language.forFileName(fileName)
        let bundle = Bundle.main
        let sysroot: URL
        do {
            sysroot = try await BundledClangSysroot.shared.prepare(
                resources: bundle.resourceURL!.appendingPathComponent("OfflineClangToolchain"),
                cacheDirectory: FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true))
        } catch {
            return RunResult(diagnostics: "", output: "", exitCode: nil,
                             failure: "Unable to prepare the offline compiler: \(error.localizedDescription)")
        }
        let compiler = OfflineCompiler(toolchain: Toolchain(
            sysroot: sysroot,
            frameworks: bundle.privateFrameworksURL ?? bundle.bundleURL.appendingPathComponent("Frameworks")))
        let result = await compiler.run(source: source, language: language,
                                        cancellation: cancellation, interactiveInput: input, events: events, includeDirectory: fileDirectory)
        // Clang compiles a temporary translation unit. Present its locations using the editor filename.
        let temporaryName = language == .cpp11 ? "main.cpp" : "main.c"
        func locations(_ text: String) -> String {
            text.replacingOccurrences(of: #"[^\s:]*MiniC-Clang-[^/\s]+/"# + temporaryName,
                                      with: NSRegularExpression.escapedTemplate(for: fileName), options: .regularExpression)
        }
        return RunResult(diagnostics: locations(result.diagnostics), output: result.output,
                         exitCode: result.exitCode, failure: result.failure.map(locations))
    }
}

/// Serialize installation off the main actor. Only completed installations are reused;
/// Caches may be purged by iOS and are rebuilt from bundled data without networking.
private actor BundledClangSysroot {
    static let shared = BundledClangSysroot()

    func prepare(resources: URL, cacheDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let identity = try Data(contentsOf: resources.appendingPathComponent("payload-id"))
        let cache = cacheDirectory.appendingPathComponent("OfflineClangToolchain", isDirectory: true)
        let marker = cache.appendingPathComponent("payload-id")
        let sysroot = cache.appendingPathComponent("usr", isDirectory: true)
        if (try? Data(contentsOf: marker)) == identity,
           fm.fileExists(atPath: sysroot.appendingPathComponent("lib/wasm32-wasi/libc.a").path) {
            return sysroot
        }

        let staging = cache.deletingLastPathComponent()
            .appendingPathComponent("OfflineClangToolchain-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedRoot = staging.appendingPathComponent("usr", isDirectory: true)
        try fm.copyItem(at: resources.appendingPathComponent("usr"), to: stagedRoot)
        var enumerationError: Error?
        guard let files = fm.enumerator(at: stagedRoot, includingPropertiesForKeys: nil,
                                       errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let file as URL in files where file.pathExtension == "base64" {
            let encoded = try Data(contentsOf: file)
            guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try decoded.write(to: file.deletingPathExtension(), options: .atomic)
            try fm.removeItem(at: file)
        }
        if let enumerationError { throw enumerationError }
        guard fm.fileExists(atPath: stagedRoot.appendingPathComponent("lib/wasm32-wasi/libc.a").path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try identity.write(to: staging.appendingPathComponent("payload-id"), options: .atomic)
        if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
        try fm.moveItem(at: staging, to: cache)
        return sysroot
    }
}
