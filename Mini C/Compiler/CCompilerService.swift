import Foundation

public struct CompilationResult: Sendable {
    public let isSuccess: Bool
    public let exitCode: Int
    public let error: String?
}

public final class CCompilerService: @unchecked Sendable {
    public static let shared = CCompilerService()
    
    private init() {}
    
    public func compileAndRun(
        source: String,
        fileName: String,
        fileDirectory: URL? = nil,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void,
        onWaitingForInput: @escaping @Sendable (Bool) -> Void
    ) -> (task: Task<CompilationResult, Never>, interpreter: CInterpreter) {
        let interpreter = CInterpreter()
        interpreter.fileName = fileName
        interpreter.onStdout = onStdout
        interpreter.onStderr = onStderr
        interpreter.onWaitingForInput = onWaitingForInput
        
        let task = Task { () -> CompilationResult in
            do {
                // Step 1: Preprocessor
                let preprocessor = CPreprocessor(fileDirectory: fileDirectory)
                let preprocessed = preprocessor.process(source: source, fileName: fileName)
                
                // Emit preprocessor diagnostics (warnings)
                for diag in preprocessor.diagnostics {
                    onStderr(diag)
                }
                
                // Pass included headers to interpreter
                interpreter.includedHeaders = preprocessor.includedHeaders
                
                // Step 2: Lexer
                let lexer = CLexer(source: preprocessed)
                let tokens = try lexer.tokenize()
                
                // Step 3: Parser
                let parser = CParser(tokens: tokens)
                let program = try parser.parse()
                
                // Step 4: Interpreter
                let exitCode = try await interpreter.execute(program: program)
                return CompilationResult(isSuccess: true, exitCode: exitCode, error: nil)
            } catch let err as CCompilerError {
                let formatted = "\(fileName):\(err.location.line):\(err.location.column): error: \(err.message)\n"
                onStderr(formatted)
                return CompilationResult(isSuccess: false, exitCode: 1, error: formatted)
            } catch let err as CRuntimeError {
                let formatted = "\(fileName): \(err.description)\n"
                onStderr(formatted)
                return CompilationResult(isSuccess: false, exitCode: 1, error: formatted)
            } catch is CancellationError {
                return CompilationResult(isSuccess: false, exitCode: -1, error: "Execution cancelled.")
            } catch {
                let formatted = "\(fileName): error: \(error.localizedDescription)\n"
                onStderr(formatted)
                return CompilationResult(isSuccess: false, exitCode: 1, error: formatted)
            }
        }
        
        return (task, interpreter)
    }
}
