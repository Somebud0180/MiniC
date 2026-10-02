import Foundation
import SwiftUI
import Combine
import MiniClang

public struct TerminalEntry: Identifiable, Equatable, Sendable {
    public enum Style: Sendable {
        case system
        case stdout
        case stderr
        case stdin
    }
    
    public let id: UUID
    public init(id: UUID = UUID(), text: String, style: Style) {
        self.id = id; self.text = text; self.style = style
    }
    public let text: String
    public let style: Style
    public let timestamp: Date = Date()
}

public enum TerminalStatus: Equatable, Sendable {
    case idle
    case compiling
    case running
    case waitingForInput
    case finished(exitCode: Int)
    case error(String)
    case cancelled
    
    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .compiling: return "Compiling"
        case .running: return "Running"
        case .waitingForInput: return "Waiting for Input"
        case .finished(let code): return "Finished (Code \(code))"
        case .error: return "Error"
        case .cancelled: return "Stopped"
        }
    }
    
    public var color: Color {
        switch self {
        case .idle: return .secondary
        case .compiling: return .yellow
        case .running: return .green
        case .waitingForInput: return .orange
        case .finished(let code): return code == 0 ? .blue : .orange
        case .error: return .red
        case .cancelled: return .secondary
        }
    }
    
    public var systemIcon: String {
        switch self {
        case .idle: return "terminal"
        case .compiling: return "gearshape.2"
        case .running: return "play.circle.fill"
        case .waitingForInput: return "keyboard"
        case .finished(let code): return code == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
}

@MainActor
public final class TerminalViewModel: ObservableObject {
    @Published public var entries: [TerminalEntry] = []
    @Published public var status: TerminalStatus = .idle
    @Published public var inputText: String = ""
    @Published public var currentFileName: String = ""
    
    private var cancellation: Cancellation?
    private var programInput: ProgramInput?
    private var generation = UUID()
    private var lastOutput = ""
    private var lastRunSource: String?
    private var lastDirectory: URL?
    @Published public private(set) var inputEnded = false

    public init() {}

    public var isRunning: Bool {
        switch status {
        case .compiling, .running, .waitingForInput: return true
        default: return false
        }
    }

    public func load(code: String, fileName: String, fileDirectory: URL? = nil) {
        if lastRunSource != code || currentFileName != fileName || lastDirectory != fileDirectory {
            stop()
            clear()
            status = .idle
        }
        lastRunSource = code
        currentFileName = fileName
        lastDirectory = fileDirectory
    }

    public func loadAndRun(code: String, fileName: String, fileDirectory: URL? = nil) {
        stop()
        load(code: code, fileName: fileName, fileDirectory: fileDirectory)
        clear()
        lastOutput = ""
        let id = UUID(); generation = id
        let token = Cancellation(), input = ProgramInput()
        cancellation = token; programInput = input
        inputText = ""; inputEnded = false
        status = .compiling
        appendEntry("=== Clang · \(Language.forFileName(fileName).rawValue) · \(fileName) ===", style: .system)
        let events = RunEvents(
            onRunning: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.status = .running
                }
            },
            onOutput: { [weak self] text in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.updateOutput(text)
                }
            },
            onWaitingForInput: { [weak self] waiting in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.status = waiting ? .waitingForInput : .running
                }
            })
        Task {
            let result = await CCompilerService.shared.compileAndRun(
                source: code, fileName: fileName, input: input, fileDirectory: fileDirectory, cancellation: token, events: events)
            guard generation == id else { return }
            // Retire callbacks as well as completion handlers from older runs.
            generation = UUID()
            programInput = nil; cancellation = nil
            updateOutput(result.output)
            if !result.diagnostics.isEmpty { appendEntry(result.diagnostics, style: .stderr) }
            if token.isCancelled {
                status = .cancelled
            } else if let failure = result.failure {
                status = .error(failure)
                appendEntry(failure, style: .stderr)
                appendEntry("=== Compilation or execution failed ===", style: .system)
            } else {
                let code = Int(result.exitCode ?? 0)
                status = .finished(exitCode: code)
                appendEntry("=== Process exited with code \(code) ===", style: .system)
            }
        }
    }

    public func rerun() {
        guard let code = lastRunSource else { return }
        loadAndRun(code: code, fileName: currentFileName, fileDirectory: lastDirectory)
    }

    public func sendInput() {
        guard isRunning, !inputEnded, let programInput else { return }
        if programInput.send(inputText + "\n") {
            appendEntry(inputText + "\n", style: .stdin)
            inputText = ""
        } else {
            appendEntry("Input limit reached (64 KiB per run).", style: .system)
        }
    }

    public func finishInput() {
        guard isRunning, !inputEnded else { return }
        programInput?.finish(); inputEnded = true
        appendEntry("=== End of input ===", style: .system)
    }

    public func stop() {
        generation = UUID()
        cancellation?.cancel(); programInput?.finish()
        cancellation = nil; programInput = nil
        if isRunning {
            status = .cancelled
            appendEntry("=== Stop requested; compiler stages finish cooperatively ===", style: .system)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    private func updateOutput(_ text: String) {
        guard text != lastOutput else { return }
        let delta = String(decoding: text.utf8.dropFirst(lastOutput.utf8.count), as: UTF8.self)
        lastOutput = text
        guard !delta.isEmpty else { return }
        if let last = entries.last, last.style == .stdout {
            entries[entries.count - 1] = TerminalEntry(id: last.id, text: last.text + delta, style: .stdout)
        } else {
            appendEntry(delta, style: .stdout)
        }
    }

    private func appendEntry(_ text: String, style: TerminalEntry.Style) {
        entries.append(TerminalEntry(text: text, style: style))
    }
}
