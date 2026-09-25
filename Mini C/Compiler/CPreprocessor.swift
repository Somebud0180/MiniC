import Foundation

public final class CPreprocessor {
    private var defines: [String: String] = [
        "__STDC__": "1",
        "__cplusplus": "202002L",
        "NULL": "0"
    ]
    private let fileDirectory: URL?
    
    public init(fileDirectory: URL? = nil) {
        self.fileDirectory = fileDirectory
    }
    
    public func process(source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var processedLines: [String] = []
        var ifStack: [Bool] = [] // tracks conditional compilation inclusion
        
        for line in lines {
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
                    // System or local include
                    // Preserved as blank line so line count in editor matches compiler error reports
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
    
    private func replaceIdentifier(_ name: String, with replacement: String, in text: String) -> String {
        guard text.contains(name) else { return text }
        // Simple word boundary regex substitution
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
