import Foundation
import OfflineClangCore

@main struct PrototypeCLI {
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--wasm" {
            do { let result = WasmRunner.run(module: try Data(contentsOf: URL(fileURLWithPath: args[2]))); report("Runtime", result) } catch { print(error); exit(1) }
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard let sdk = env["MINIC_WASI_SDK"], let root = env["MINIC_SYSROOT"] else { print("Set MINIC_WASI_SDK and MINIC_SYSROOT. See docs/offline-clang-prototype.md."); exit(1) }
        let compiler = OfflineCompiler(toolchain: .init(sysroot: URL(fileURLWithPath: root), frameworks: URL(fileURLWithPath: "/unused"), hostSDK: URL(fileURLWithPath: sdk)))
        if args.count == 3, args[1] == "--emit-samples" {
            let destination = URL(fileURLWithPath: args[2]); try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (index, name) in [(0, "c99"), (1, "cpp11"), (2, "stdin"), (4, "loop"), (5, "output")] {
                let work = destination.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: work) }
                    let example = CompilerExample.all[index]
                    let (module, _) = try compiler.compile(source: example.source, language: example.language, directory: work)
                    try Data(contentsOf: module).write(to: destination.appendingPathComponent(name + ".wasm"))
                    try example.source.write(to: destination.appendingPathComponent(name + (example.language == .c99 ? ".c" : ".cpp")), atomically: true, encoding: .utf8)
                } catch { print(error); exit(1) }
            }
            return
        }
        let results = await PrototypeVerification.run(compiler: compiler)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! encoder.encode(results), as: UTF8.self))
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    static func report(_ name: String, _ result: RunResult) {
        print("\n[\(name)] exit=\(result.exitCode.map(String.init) ?? "none")")
        if !result.diagnostics.isEmpty { print(result.diagnostics) }
        if !result.output.isEmpty { print(String(result.output.prefix(2000))) }
        if let failure = result.failure { print(failure) }
    }
}
