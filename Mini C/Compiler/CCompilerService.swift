import Foundation
import OfflineClangCore

/// The editor and terminal use the same bundled Clang → WebAssembly engine as the lab.
@MainActor
public final class CCompilerService {
    public static let shared = CCompilerService()
    private let compiler: OfflineCompiler

    public init() {
        let bundle = Bundle.main
        compiler = OfflineCompiler(toolchain: Toolchain(
            sysroot: bundle.resourceURL!.appendingPathComponent("OfflineClangToolchain/usr"),
            frameworks: bundle.privateFrameworksURL ?? bundle.bundleURL.appendingPathComponent("Frameworks")))
    }

    public func compileAndRun(source: String, fileName: String, input: ProgramInput, fileDirectory: URL?,
                              cancellation: Cancellation, events: RunEvents) async -> RunResult {
        let language = Language.forFileName(fileName)
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
