import XCTest
@testable import OfflineClangCore

final class RuntimeTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "wasm", subdirectory: "Fixtures")))
    }
    func testC99Semantics() throws {
        let result = WasmRunner.run(module: try fixture("c99"))
        XCTAssertTrue(result.succeeded, result.failure ?? "")
        XCTAssertEqual(result.output, "3 7 9 1 1\n")
    }
    func testCpp11Library() throws {
        let result = WasmRunner.run(module: try fixture("cpp11"))
        XCTAssertTrue(result.succeeded, result.failure ?? "")
        XCTAssertEqual(result.output, "1 4 9 14\n")
    }
    func testInputAndEOF() throws {
        let module = try fixture("stdin")
        XCTAssertEqual(WasmRunner.run(module: module, input: "20 22\n").output, "sum = 42\n")
        XCTAssertEqual(WasmRunner.run(module: module).exitCode, 1)
    }
    func testFuelStopsAnInfiniteLoop() throws {
        let result = WasmRunner.run(module: try fixture("loop"), fuel: 10_000)
        XCTAssertTrue(result.failure?.contains("fuel") == true, result.failure ?? "")
    }
    func testOutputIsBoundedAndNextRunWorks() throws {
        let result = WasmRunner.run(module: try fixture("output"))
        XCTAssertTrue(result.failure?.contains("Output exceeded") == true, result.failure ?? "")
        XCTAssertLessThanOrEqual(result.output.utf8.count, 256 * 1024)
        XCTAssertTrue(WasmRunner.run(module: try fixture("c99")).succeeded)
    }
    func testMalformedModuleAndCancellation() throws {
        XCTAssertNotNil(WasmRunner.run(module: Data([0, 1, 2])).failure)
        let cancellation = Cancellation(); cancellation.cancel()
        XCTAssertEqual(WasmRunner.run(module: try fixture("loop"), cancellation: cancellation).failure, "Stopped.")
    }
    func testInitialMemoryCapAndModuleSizeLimit() {
        // A well-formed module requesting 1025 pages: one page beyond 64 MiB.
        let memory = Data([0,97,115,109,1,0,0,0,5,4,1,0,0x81,0x08])
        XCTAssertTrue(WasmRunner.run(module: memory).failure?.lowercased().contains("memory") == true)
        XCTAssertEqual(WasmRunner.run(module: Data(repeating: 0, count: 16 * 1024 * 1024 + 1)).failure, "Module or input exceeds prototype limits.")
    }
    func testEditorLanguageSelection() {
        for name in ["hello.cpp", "hello.cc", "hello.cxx", "hello.C", "hello.CPP"] {
            XCTAssertEqual(Language.forFileName(name), .cpp11)
        }
        XCTAssertEqual(Language.forFileName("hello.c"), .c99)
    }
    func testInteractiveInputAndEOF() async throws {
        let module = try fixture("stdin")
        let input = ProgramInput()
        let waiting = expectation(description: "guest waits for stdin")
        waiting.assertForOverFulfill = false
        let task = Task.detached {
            WasmRunner.run(module: module, interactiveInput: input,
                           events: RunEvents(onWaitingForInput: { if $0 { waiting.fulfill() } }))
        }
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertTrue(input.send("20 22\n"))
        input.finish()
        let result = await task.value
        XCTAssertEqual(result.output, "sum = 42\n")
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(input.send("too late"))
        let eof = ProgramInput(); eof.finish()
        XCTAssertEqual(WasmRunner.run(module: module, interactiveInput: eof).exitCode, 1)
    }
    func testStopWhileWaitingForInput() async throws {
        let module = try fixture("stdin")
        let input = ProgramInput(), cancellation = Cancellation()
        let waiting = expectation(description: "waiting")
        let task = Task.detached {
            WasmRunner.run(module: module, cancellation: cancellation, interactiveInput: input,
                           events: RunEvents(onWaitingForInput: { if $0 { waiting.fulfill() } }))
        }
        await fulfillment(of: [waiting], timeout: 5)
        cancellation.cancel()
        let result = await task.value
        XCTAssertEqual(result.failure, "Stopped.")
    }
    func testInteractiveInputLimit() {
        let input = ProgramInput()
        XCTAssertTrue(input.send(String(repeating: "a", count: 64 * 1024)))
        XCTAssertFalse(input.send("b"))
    }
    func testLocalHeaderLookup() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sdk = env["MINIC_WASI_SDK"], let root = env["MINIC_SYSROOT"] else { throw XCTSkip("Desktop SDK needed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "#define ANSWER 42\n".write(to: folder.appendingPathComponent("answer.h"), atomically: true, encoding: .utf8)
        let compiler = OfflineCompiler(toolchain: .init(sysroot: URL(fileURLWithPath: root), frameworks: folder, hostSDK: URL(fileURLWithPath: sdk)))
        let result = await compiler.run(source: "#include \"answer.h\"\nint main(void) { return ANSWER; }", language: .c99, includeDirectory: folder)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.exitCode, 42)
    }
    func testUnflushedPromptsBeforeEachScan() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sdk = env["MINIC_WASI_SDK"], let root = env["MINIC_SYSROOT"] else { throw XCTSkip("Desktop SDK needed") }
        let compiler = OfflineCompiler(toolchain: .init(sysroot: URL(fileURLWithPath: root), frameworks: URL(fileURLWithPath: "/unused"), hostSDK: URL(fileURLWithPath: sdk)))
        let sourceURL = try XCTUnwrap(Bundle.module.url(forResource: "school-supplies", withExtension: "c", subdirectory: "Fixtures"))
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let probe = PromptProbe()
        let input = ProgramInput()
        let prompts = ["Input price of notebook: ", "Input quantity of notebook: ", "Input price of ballpen: ", "Input quantity of ballpen: ", "Input price of pencil: ", "Input quantity of pencil: "]
        let answers = ["10", "5", "5", "4", "6", "2"]
        let result = await compiler.run(source: source, language: .c99, interactiveInput: input,
            events: RunEvents(onOutput: { probe.output = $0 }, onWaitingForInput: { waiting in
                guard waiting else { return }
                let index = probe.checks.count
                guard index < prompts.count else { input.finish(); return }
                probe.checks.append(probe.output.hasSuffix(prompts[index]))
                input.send(answers[index] + "\n")
                if index == prompts.count - 1 { input.finish() }
            }))
        XCTAssertTrue(result.succeeded, result.failure ?? "")
        XCTAssertEqual(probe.checks, Array(repeating: true, count: 6), "Every prompt must reach the terminal before its scanf reads input")
        XCTAssertTrue(result.output.contains("Total Cost: 82.00"))
    }
    func testSourceCompilerProbes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sdk = env["MINIC_WASI_SDK"], let root = env["MINIC_SYSROOT"] else { throw XCTSkip("Set MINIC_WASI_SDK and MINIC_SYSROOT for end-to-end compiler tests") }
        let compiler = OfflineCompiler(toolchain: .init(sysroot: URL(fileURLWithPath: root), frameworks: URL(fileURLWithPath: "/unused"), hostSDK: URL(fileURLWithPath: sdk)))
        for result in await PrototypeVerification.run(compiler: compiler) { XCTAssertTrue(result.passed, "\(result.name): \(result.failure ?? result.output)") }
    }
}

// Callbacks are serialized on the compiler worker; assertions run after completion.
private final class PromptProbe: @unchecked Sendable {
    var output = ""
    var checks: [Bool] = []
}
