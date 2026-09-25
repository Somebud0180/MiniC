import Foundation

public final class CPreprocessor {
    private var defines: [String: String] = [
        "__STDC__": "1",
        "__cplusplus": "202002L",
        "NULL": "0"
    ]
    private let fileDirectory: URL?
    
    public private(set) var diagnostics: [String] = []
    public private(set) var includedHeaders: Set<String> = []
    
    public init(fileDirectory: URL? = nil) {
        self.fileDirectory = fileDirectory
    }
    
    public func process(source: String, fileName: String = "") -> String {
        let lines = source.components(separatedBy: "\n")
        var processedLines: [String] = []
        var ifStack: [Bool] = [] // tracks conditional compilation inclusion
        
        for (lineIdx, line) in lines.enumerated() {
            let lineNum = lineIdx + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#") {
                let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                
                if directive.hasPrefix("ifdef ") {
                    let macro = directive.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    let parentActive = ifStack.allSatisfy { $0 }
                    let isDefined = defines.keys.contains(macro)
                    ifStack.append(parentActive && isDefined)
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("ifndef ") {
                    let macro = directive.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    let parentActive = ifStack.allSatisfy { $0 }
                    let isNotDefined = !defines.keys.contains(macro)
                    ifStack.append(parentActive && isNotDefined)
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("if ") {
                    let cond = directive.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    let parentActive = ifStack.allSatisfy { $0 }
                    let isTrue = (cond == "1" || defines.keys.contains(cond))
                    ifStack.append(parentActive && isTrue)
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("elif ") {
                    if !ifStack.isEmpty {
                        let cond = directive.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let isTrue = (cond == "1" || defines.keys.contains(cond))
                        ifStack[ifStack.count - 1] = isTrue
                    }
                    processedLines.append("")
                    continue
                } else if directive == "else" {
                    if !ifStack.isEmpty {
                        let prev = ifStack.removeLast()
                        ifStack.append(!prev)
                    }
                    processedLines.append("")
                    continue
                } else if directive == "endif" {
                    if !ifStack.isEmpty {
                        _ = ifStack.removeLast()
                    }
                    processedLines.append("")
                    continue
                }
                
                // If currently inside a disabled conditional block, skip
                if !ifStack.allSatisfy({ $0 }) {
                    processedLines.append("")
                    continue
                }
                
                if directive.hasPrefix("include") {
                    let includePart = directive.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    processInclude(includePart, lineNum: lineNum, fileName: fileName)
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("define ") {
                    let rest = directive.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if let name = parts.first {
                        let val = parts.count > 1 ? String(parts[1]) : "1"
                        defines[String(name)] = val
                    }
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("undef ") {
                    let name = directive.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    defines.removeValue(forKey: name)
                    processedLines.append("")
                    continue
                } else {
                    // Unknown pragma or directive, blank out
                    processedLines.append("")
                    continue
                }
            }
            
            // Check if active branch
            if !ifStack.allSatisfy({ $0 }) {
                processedLines.append("")
                continue
            }
            
            // Perform macro substitution for defines
            var lineOut = line
            for (macro, replacement) in defines where macro != "NULL" {
                lineOut = replaceIdentifier(macro, with: replacement, in: lineOut)
            }
            processedLines.append(lineOut)
        }
        
        return processedLines.joined(separator: "\n")
    }
    
    // MARK: - Include Validation & Header Processing
    
    private func processInclude(_ rawInclude: String, lineNum: Int, fileName: String) {
        var header = rawInclude.trimmingCharacters(in: .whitespaces)
        let isSystem = header.hasPrefix("<") && header.hasSuffix(">")
        let isUser = header.hasPrefix("\"") && header.hasSuffix("\"")
        
        if isSystem || isUser {
            header = String(header.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        
        let filePrefix = fileName.isEmpty ? "" : "\(fileName):\(lineNum): "
        
        if isUser {
            // Check if local header file exists in fileDirectory
            if let fileDirectory = fileDirectory {
                let candidateURL = fileDirectory.appendingPathComponent(header)
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    includedHeaders.insert(header)
                    return
                }
            }
            // Check if user wrote a standard header with quotes e.g. #include "stdio.h"
            if isSupportedStandardHeader(header) {
                includedHeaders.insert(header)
                defineHeaderMacros(header)
                return
            }
            diagnostics.append("\(filePrefix)warning: header '\(header)' not found; skipping include.\n")
            return
        }
        
        // System header: <...>
        if isSupportedStandardHeader(header) {
            includedHeaders.insert(header)
            defineHeaderMacros(header)
        } else if isKnownUnsupportedHeader(header) {
            diagnostics.append("\(filePrefix)warning: header <\(header)> is not supported in Mini C runtime. Built-in functions and types from this library will not be available.\n")
        } else {
            diagnostics.append("\(filePrefix)warning: header <\(header)> not found or unsupported in Mini C runtime.\n")
        }
    }
    
    private func isSupportedStandardHeader(_ name: String) -> Bool {
        let supported: Set<String> = [
            "stdio.h", "cstdio",
            "unistd.h", "unistd",
            "stdlib.h", "cstdlib",
            "string.h", "cstring",
            "ctype.h", "cctype",
            "math.h", "cmath",
            "time.h", "ctime",
            "assert.h", "cassert",
            "stdbool.h",
            "stdint.h", "cstdint",
            "stddef.h", "cstddef",
            "limits.h", "climits",
            "float.h", "cfloat",
            "errno.h", "cerrno",
            "fcntl.h",
            "sys/types.h", "sys/stat.h", "sys/time.h",
            "iostream", "vector", "string", "algorithm",
            "utility", "memory", "map", "set", "sstream",
            "iomanip", "iterator", "stdexcept"
        ]
        return supported.contains(name)
    }
    
    private func isKnownUnsupportedHeader(_ name: String) -> Bool {
        let unsupported: Set<String> = [
            "pthread.h",
            "sys/socket.h", "netinet/in.h", "arpa/inet.h", "netdb.h",
            "sys/mman.h", "sys/wait.h", "sys/select.h", "sys/poll.h",
            "signal.h", "regex.h", "dlfcn.h",
            "windows.h", "conio.h", "dos.h",
            "curl/curl.h", "openssl/ssl.h", "sqlite3.h",
            "dirent.h", "semaphore.h", "threads.h"
        ]
        return unsupported.contains(name)
    }
    
    private func defineHeaderMacros(_ header: String) {
        switch header {
        case "unistd.h", "unistd":
            defines["STDIN_FILENO"] = "0"
            defines["STDOUT_FILENO"] = "1"
            defines["STDERR_FILENO"] = "2"
            defines["F_OK"] = "0"
            defines["X_OK"] = "1"
            defines["W_OK"] = "2"
            defines["R_OK"] = "4"
            defines["SEEK_SET"] = "0"
            defines["SEEK_CUR"] = "1"
            defines["SEEK_END"] = "2"
        case "stdlib.h", "cstdlib":
            defines["EXIT_SUCCESS"] = "0"
            defines["EXIT_FAILURE"] = "1"
            defines["RAND_MAX"] = "2147483647"
        case "math.h", "cmath":
            defines["M_PI"] = "3.141592653589793"
            defines["M_E"] = "2.718281828459045"
        case "time.h", "ctime":
            defines["CLOCKS_PER_SEC"] = "1000"
        case "stdio.h", "cstdio":
            defines["EOF"] = "-1"
            defines["BUFSIZ"] = "1024"
            defines["FILENAME_MAX"] = "1024"
        default:
            break
        }
    }
    
    private func replaceIdentifier(_ name: String, with replacement: String, in text: String) -> String {
        guard text.contains(name) else { return text }
        // Simple word boundary regex substitution
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
