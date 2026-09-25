import Foundation
import SwiftUI
import Combine

public struct TerminalEntry: Identifiable, Equatable, Sendable {
    public enum Style: Sendable {
        case system
        case stdout
        case stderr
        case stdin
    }
    
    public let id = UUID()
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
    
    private var currentExecutionTask: Task<CompilationResult, Never>? = nil
    private var currentInterpreter: CInterpreter? = nil
    private var lastRunSource: String? = nil
    
    public init() {}
    
    public var isRunning: Bool {
        switch status {
        case .compiling, .running, .waitingForInput:
            return true
        default:
            return false
        }
    }
    
    public func load(code: String, fileName: String) {
        if lastRunSource != code && currentFileName != fileName {
            clear()
        }
        
        lastRunSource = code
        currentFileName = fileName
    }
    
    public func loadAndRun(code: String, fileName: String) {
        // If already running, cancel previous
        stop()
        
        load(code: code, fileName: fileName)
        status = .compiling
        
        appendEntry("=== Building \(fileName) ===", style: .system)
        
        let (task, interpreter) = CCompilerService.shared.compileAndRun(
            source: code,
            fileName: fileName,
            onStdout: { [weak self] text in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.appendEntry(text, style: .stdout)
                }
            },
            onStderr: { [weak self] text in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.appendEntry(text, style: .stderr)
                }
            },
            onWaitingForInput: { [weak self] isWaiting in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    if isWaiting {
                        self?.status = .waitingForInput
                    } else if self?.status == .waitingForInput {
                        self?.status = .running
                    }
                }
            }
        )
        
        currentExecutionTask = task
        currentInterpreter = interpreter
        status = .running
        
        Task {
            let result = await task.value
            if Task.isCancelled { return }
            
            if result.isSuccess {
                self.status = .finished(exitCode: result.exitCode)
                self.appendEntry("=== Process exited with code \(result.exitCode) ===", style: .system)
            } else if result.exitCode == -1 {
                self.status = .cancelled
                self.appendEntry("=== Process terminated ===", style: .system)
            } else {
                self.status = .error(result.error ?? "Compilation failed")
                self.appendEntry("=== Build failed ===", style: .system)
            }
        }
    }
    
    public func rerun() {
        guard let code = lastRunSource else { return }
        loadAndRun(code: code, fileName: currentFileName)
    }
    
    public func sendInput() {
        let textToSend = inputText
        guard !textToSend.isEmpty || status == .waitingForInput else { return }
        
        appendEntry(textToSend + "\n", style: .stdin)
        inputText = ""
        currentInterpreter?.provideInput(textToSend)
    }
    
    public func stop() {
        currentInterpreter?.cancel()
        currentExecutionTask?.cancel()
        currentExecutionTask = nil
        currentInterpreter = nil
        if isRunning {
            status = .cancelled
            appendEntry("=== Stopped by user ===", style: .system)
        }
    }
    
    public func clear() {
        entries.removeAll()
    }
    
    private func appendEntry(_ text: String, style: TerminalEntry.Style) {
        // If the last entry has the same style and does not end with newline, we can merge or append
        entries.append(TerminalEntry(text: text, style: style))
    }
}
