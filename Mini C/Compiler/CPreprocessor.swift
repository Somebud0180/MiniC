import Foundation

public final class CPreprocessor {
    public struct Macro: Sendable {
        public let name: String
        public let parameters: [String]? // nil = object-like macro
        public let isVariadic: Bool
        public let replacement: String
        
        public init(name: String, parameters: [String]?, isVariadic: Bool = false, replacement: String) {
            self.name = name
            self.parameters = parameters
            self.isVariadic = isVariadic
            self.replacement = replacement
        }
    }
    
    private var macros: [String: Macro] = [
        "__STDC__": Macro(name: "__STDC__", parameters: nil, replacement: "1"),
        "__STDC_VERSION__": Macro(name: "__STDC_VERSION__", parameters: nil, replacement: "199901L"),
        "__cplusplus": Macro(name: "__cplusplus", parameters: nil, replacement: "201703L"),
        "NULL": Macro(name: "NULL", parameters: nil, replacement: "0")
    ]
    private let fileDirectory: URL?
    
    public private(set) var diagnostics: [String] = []
    public private(set) var includedHeaders: Set<String> = []
    
    public init(fileDirectory: URL? = nil) {
        self.fileDirectory = fileDirectory
    }
    
    // MARK: - Translation Phases 1 to 4
    
    public func process(source: String, fileName: String = "") -> String {
        // Phase 1 & 2: Splicing backslash-newlines (line continuation)
        let spliced = spliceLineContinuations(source)
        
        // Phase 3 & 4: Process line-by-line directives with conditional compilation
        let lines = spliced.components(separatedBy: "\n")
        var processedLines: [String] = []
        
        // Tracks: (parentActive: Bool, hasBranchTaken: Bool, currentBranchActive: Bool)
        var ifStack: [(parentActive: Bool, branchTaken: Bool, currentActive: Bool)] = []
        
        var lineIdx = 0
        while lineIdx < lines.count {
            let line = lines[lineIdx]
            let lineNum = lineIdx + 1
            lineIdx += 1
            
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isParentActive = ifStack.allSatisfy { $0.currentActive }
            
            if trimmed.hasPrefix("#") {
                let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                
                if directive.hasPrefix("ifdef ") {
                    let macroName = directive.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    let isDefined = macros.keys.contains(macroName)
                    let active = isParentActive && isDefined
                    ifStack.append((parentActive: isParentActive, branchTaken: isDefined, currentActive: active))
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("ifndef ") {
                    let macroName = directive.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    let isNotDefined = !macros.keys.contains(macroName)
                    let active = isParentActive && isNotDefined
                    ifStack.append((parentActive: isParentActive, branchTaken: isNotDefined, currentActive: active))
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("if ") {
                    let expr = directive.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    let condValue = isParentActive ? evaluateConstantExpression(expr) : 0
                    let isTrue = condValue != 0
                    let active = isParentActive && isTrue
                    ifStack.append((parentActive: isParentActive, branchTaken: isTrue, currentActive: active))
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("elif ") {
                    if !ifStack.isEmpty {
                        var top = ifStack.removeLast()
                        if top.parentActive && !top.branchTaken {
                            let expr = directive.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            let condValue = evaluateConstantExpression(expr)
                            let isTrue = condValue != 0
                            top.branchTaken = isTrue
                            top.currentActive = isTrue
                        } else {
                            top.currentActive = false
                        }
                        ifStack.append(top)
                    }
                    processedLines.append("")
                    continue
                } else if directive == "else" {
                    if !ifStack.isEmpty {
                        var top = ifStack.removeLast()
                        if top.parentActive && !top.branchTaken {
                            top.branchTaken = true
                            top.currentActive = true
                        } else {
                            top.currentActive = false
                        }
                        ifStack.append(top)
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
                
                // If inactive conditional branch, skip directives except conditionals
                if !isParentActive {
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
                    parseDefine(rest)
                    processedLines.append("")
                    continue
                } else if directive.hasPrefix("undef ") {
                    let name = directive.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    macros.removeValue(forKey: name)
                    processedLines.append("")
                    continue
                } else {
                    // Unknown pragma or directive, blank out
                    processedLines.append("")
                    continue
                }
            }
            
            // Check if active branch
            if !isParentActive {
                processedLines.append("")
                continue
            }
            
            macros["__LINE__"] = Macro(name: "__LINE__", parameters: nil, replacement: "\(lineNum)")
            let curFile = fileName.isEmpty ? "main.cpp" : fileName
            macros["__FILE__"] = Macro(name: "__FILE__", parameters: nil, replacement: "\"" + curFile + "\"")
            
            // Perform standard macro expansion
            let expandedLine = expandMacros(in: line, hideSet: [])
            processedLines.append(expandedLine)
        }
        
        return processedLines.joined(separator: "\n")
    }
    
    // MARK: - Line Splicing (Phase 2)
    
    private func spliceLineContinuations(_ text: String) -> String {
        return text.replacingOccurrences(of: "\\\r\n", with: "")
                   .replacingOccurrences(of: "\\\n", with: "")
    }
    
    // MARK: - Macro Definition Parser
    
    private func parseDefine(_ text: String) {
        let str = text.trimmingCharacters(in: .whitespaces)
        guard let firstChar = str.first, (firstChar.isLetter || firstChar == "_") else { return }
        
        // Check if function-like: NAME(...)
        if let parenIdx = str.firstIndex(of: "(") {
            let beforeParen = str[..<parenIdx]
            // Function-like macro requires NO space between name and '('
            if !beforeParen.contains(" ") && !beforeParen.contains("\t") {
                let name = String(beforeParen)
                let afterParen = str[str.index(after: parenIdx)...]
                if let closeParenIdx = afterParen.firstIndex(of: ")") {
                    let paramStr = String(afterParen[..<closeParenIdx]).trimmingCharacters(in: .whitespaces)
                    let body = String(afterParen[afterParen.index(after: closeParenIdx)...]).trimmingCharacters(in: .whitespaces)
                    
                    var params: [String] = []
                    var isVariadic = false
                    if !paramStr.isEmpty {
                        let rawParams = paramStr.components(separatedBy: ",")
                        for p in rawParams {
                            let cleanP = p.trimmingCharacters(in: .whitespaces)
                            if cleanP == "..." {
                                isVariadic = true
                                params.append("__VA_ARGS__")
                            } else {
                                params.append(cleanP)
                            }
                        }
                    }
                    macros[name] = Macro(name: name, parameters: params, isVariadic: isVariadic, replacement: body)
                    return
                }
            }
        }
        
        // Object-like macro
        let parts = str.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let namePart = parts.first {
            let name = String(namePart)
            let replacement = parts.count > 1 ? String(parts[1]) : "1"
            macros[name] = Macro(name: name, parameters: nil, replacement: replacement)
        }
    }
    
    // MARK: - Macro Expansion with Hide-Set (Blue Painting)
    
    public func expandMacros(in text: String, hideSet: Set<String>) -> String {
        var result = ""
        var i = text.startIndex
        
        while i < text.endIndex {
            let ch = text[i]
            
            // Skip string and char literals from macro expansion
            if ch == "\"" || ch == "'" {
                let quote = ch
                result.append(ch)
                i = text.index(after: i)
                while i < text.endIndex {
                    let c = text[i]
                    result.append(c)
                    if c == "\\" {
                        i = text.index(after: i)
                        if i < text.endIndex {
                            result.append(text[i])
                            i = text.index(after: i)
                        }
                        continue
                    }
                    i = text.index(after: i)
                    if c == quote { break }
                }
                continue
            }
            
            if ch.isLetter || ch == "_" {
                let wordStart = i
                while i < text.endIndex && (text[i].isLetter || text[i].isNumber || text[i] == "_") {
                    i = text.index(after: i)
                }
                let identifier = String(text[wordStart..<i])
                
                if let macro = macros[identifier], !hideSet.contains(identifier) {
                    if macro.parameters != nil {
                        // Function-like macro: peek for opening '('
                        var lookAhead = i
                        while lookAhead < text.endIndex && text[lookAhead].isWhitespace {
                            lookAhead = text.index(after: lookAhead)
                        }
                        
                        if lookAhead < text.endIndex && text[lookAhead] == "(" {
                            // Collect balanced arguments
                            if let (args, afterCallIdx) = parseMacroArguments(in: text, openParenIdx: lookAhead) {
                                i = afterCallIdx
                                let expandedBody = substituteParameters(macro: macro, args: args)
                                // Rescan with hide-set
                                let rescanned = expandMacros(in: expandedBody, hideSet: hideSet.union([identifier]))
                                result.append(rescanned)
                                continue
                            }
                        }
                        result.append(identifier)
                    } else {
                        // Object-like macro: expand and rescan
                        let rescanned = expandMacros(in: macro.replacement, hideSet: hideSet.union([identifier]))
                        result.append(rescanned)
                    }
                } else {
                    result.append(identifier)
                }
            } else {
                result.append(ch)
                i = text.index(after: i)
            }
        }
        
        return result
    }
    
    private func parseMacroArguments(in text: String, openParenIdx: String.Index) -> ([String], String.Index)? {
        var args: [String] = []
        var currentArg = ""
        var depth = 1
        var i = text.index(after: openParenIdx)
        
        while i < text.endIndex && depth > 0 {
            let ch = text[i]
            if ch == "\"" || ch == "'" {
                let quote = ch
                currentArg.append(ch)
                i = text.index(after: i)
                while i < text.endIndex {
                    let c = text[i]
                    currentArg.append(c)
                    if c == "\\" {
                        i = text.index(after: i)
                        if i < text.endIndex {
                            currentArg.append(text[i])
                            i = text.index(after: i)
                        }
                        continue
                    }
                    i = text.index(after: i)
                    if c == quote { break }
                }
                continue
            }
            
            if ch == "(" {
                depth += 1
                currentArg.append(ch)
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    args.append(currentArg.trimmingCharacters(in: .whitespaces))
                    return (args, text.index(after: i))
                } else {
                    currentArg.append(ch)
                }
            } else if ch == "," && depth == 1 {
                args.append(currentArg.trimmingCharacters(in: .whitespaces))
                currentArg = ""
            } else {
                currentArg.append(ch)
            }
            i = text.index(after: i)
        }
        return nil
    }
    
    private func substituteParameters(macro: Macro, args: [String]) -> String {
        guard let params = macro.parameters else { return macro.replacement }
        var body = macro.replacement
        
        var paramMap: [String: String] = [:]
        for (idx, param) in params.enumerated() {
            if param == "__VA_ARGS__" {
                let rest = args.count > idx ? args[idx...].joined(separator: ", ") : ""
                paramMap["__VA_ARGS__"] = rest
            } else if idx < args.count {
                paramMap[param] = args[idx]
            } else {
                paramMap[param] = ""
            }
        }
        
        // 1. Stringification: #param
        for (param, val) in paramMap {
            let escapedVal = val.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let stringized = "\"\(escapedVal)\""
            let pattern = "#\\s*\\b\(NSRegularExpression.escapedPattern(for: param))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(body.startIndex..., in: body)
                body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: stringized))
            }
        }
        
        // 2. Token Pasting: a ## b
        for (param, val) in paramMap {
            let leftPattern = "\\b\(NSRegularExpression.escapedPattern(for: param))\\s*##"
            if let regex = try? NSRegularExpression(pattern: leftPattern) {
                let range = NSRange(body.startIndex..., in: body)
                body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: val)
            }
            let rightPattern = "##\\s*\\b\(NSRegularExpression.escapedPattern(for: param))\\b"
            if let regex = try? NSRegularExpression(pattern: rightPattern) {
                let range = NSRange(body.startIndex..., in: body)
                body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: val)
            }
        }
        
        // 3. Regular parameter replacement
        for (param, val) in paramMap {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: param))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(body.startIndex..., in: body)
                body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: val))
            }
        }
        
        return body
    }
    
    // MARK: - Constant Expression Evaluator for #if / #elif
    
    public func evaluateConstantExpression(_ expr: String) -> Int64 {
        // Step A: Replace defined(X) and defined X
        var prepared = expr
        let definedRegex = try? NSRegularExpression(pattern: "defined\\s*(?:\\((\\w+)\\)|(\\w+))")
        if let regex = definedRegex {
            let matches = regex.matches(in: prepared, range: NSRange(prepared.startIndex..., in: prepared)).reversed()
            for match in matches {
                var macroName = ""
                if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: prepared) {
                    macroName = String(prepared[r])
                } else if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: prepared) {
                    macroName = String(prepared[r])
                }
                let isDef = macros.keys.contains(macroName) ? "1" : "0"
                if let fullRange = Range(match.range, in: prepared) {
                    prepared.replaceSubrange(fullRange, with: isDef)
                }
            }
        }
        
        // Step B: Expand remaining macros in expression
        prepared = expandMacros(in: prepared, hideSet: [])
        
        // Step C: ISO C99 §6.10.1p4: Any remaining identifiers evaluate to 0
        let identRegex = try? NSRegularExpression(pattern: "\\b[a-zA-Z_]\\w*\\b")
        if let regex = identRegex {
            let matches = regex.matches(in: prepared, range: NSRange(prepared.startIndex..., in: prepared)).reversed()
            for m in matches {
                if let r = Range(m.range, in: prepared) {
                    prepared.replaceSubrange(r, with: "0")
                }
            }
        }
        
        // Step D: Evaluate arithmetic/logical expression
        let tokens = tokenizeConstExpr(prepared)
        var pos = 0
        return parseConstLogicalOr(tokens, &pos)
    }
    
    private func tokenizeConstExpr(_ text: String) -> [String] {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace {
                i = text.index(after: i)
                continue
            }
            if ch.isNumber {
                let start = i
                if ch == "0" && i < text.index(before: text.endIndex) {
                    let next = text[text.index(after: i)]
                    if next == "x" || next == "X" {
                        i = text.index(i, offsetBy: 2)
                        while i < text.endIndex && text[i].isHexDigit {
                            i = text.index(after: i)
                        }
                        tokens.append(String(text[start..<i]))
                        continue
                    }
                }
                while i < text.endIndex && text[i].isNumber {
                    i = text.index(after: i)
                }
                tokens.append(String(text[start..<i]))
                continue
            }
            
            // Two-character operators
            let twoOps = ["&&", "||", "==", "!=", "<=", ">=", "<<", ">>"]
            var matchedTwo = false
            for op in twoOps {
                if text[i...].hasPrefix(op) {
                    tokens.append(op)
                    i = text.index(i, offsetBy: op.count)
                    matchedTwo = true
                    break
                }
            }
            if matchedTwo { continue }
            
            tokens.append(String(ch))
            i = text.index(after: i)
        }
        return tokens
    }
    
    private func parseConstLogicalOr(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstLogicalAnd(tokens, &pos)
        while pos < tokens.count && tokens[pos] == "||" {
            pos += 1
            let rhs = parseConstLogicalAnd(tokens, &pos)
            lhs = (lhs != 0 || rhs != 0) ? 1 : 0
        }
        return lhs
    }
    
    private func parseConstLogicalAnd(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstBitwiseOr(tokens, &pos)
        while pos < tokens.count && tokens[pos] == "&&" {
            pos += 1
            let rhs = parseConstBitwiseOr(tokens, &pos)
            lhs = (lhs != 0 && rhs != 0) ? 1 : 0
        }
        return lhs
    }
    
    private func parseConstBitwiseOr(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstBitwiseXor(tokens, &pos)
        while pos < tokens.count && tokens[pos] == "|" {
            pos += 1
            let rhs = parseConstBitwiseXor(tokens, &pos)
            lhs = lhs | rhs
        }
        return lhs
    }
    
    private func parseConstBitwiseXor(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstBitwiseAnd(tokens, &pos)
        while pos < tokens.count && tokens[pos] == "^" {
            pos += 1
            let rhs = parseConstBitwiseAnd(tokens, &pos)
            lhs = lhs ^ rhs
        }
        return lhs
    }
    
    private func parseConstBitwiseAnd(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstEquality(tokens, &pos)
        while pos < tokens.count && tokens[pos] == "&" {
            pos += 1
            let rhs = parseConstEquality(tokens, &pos)
            lhs = lhs & rhs
        }
        return lhs
    }
    
    private func parseConstEquality(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstRelational(tokens, &pos)
        while pos < tokens.count && (tokens[pos] == "==" || tokens[pos] == "!=") {
            let op = tokens[pos]
            pos += 1
            let rhs = parseConstRelational(tokens, &pos)
            lhs = op == "==" ? (lhs == rhs ? 1 : 0) : (lhs != rhs ? 1 : 0)
        }
        return lhs
    }
    
    private func parseConstRelational(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstShift(tokens, &pos)
        while pos < tokens.count && ["<", "<=", ">", ">="].contains(tokens[pos]) {
            let op = tokens[pos]
            pos += 1
            let rhs = parseConstShift(tokens, &pos)
            switch op {
            case "<": lhs = lhs < rhs ? 1 : 0
            case "<=": lhs = lhs <= rhs ? 1 : 0
            case ">": lhs = lhs > rhs ? 1 : 0
            case ">=": lhs = lhs >= rhs ? 1 : 0
            default: break
            }
        }
        return lhs
    }
    
    private func parseConstShift(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstAdditive(tokens, &pos)
        while pos < tokens.count && (tokens[pos] == "<<" || tokens[pos] == ">>") {
            let op = tokens[pos]
            pos += 1
            let rhs = parseConstAdditive(tokens, &pos)
            lhs = op == "<<" ? (lhs << rhs) : (lhs >> rhs)
        }
        return lhs
    }
    
    private func parseConstAdditive(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstMultiplicative(tokens, &pos)
        while pos < tokens.count && (tokens[pos] == "+" || tokens[pos] == "-") {
            let op = tokens[pos]
            pos += 1
            let rhs = parseConstMultiplicative(tokens, &pos)
            lhs = op == "+" ? (lhs + rhs) : (lhs - rhs)
        }
        return lhs
    }
    
    private func parseConstMultiplicative(_ tokens: [String], _ pos: inout Int) -> Int64 {
        var lhs = parseConstUnary(tokens, &pos)
        while pos < tokens.count && (tokens[pos] == "*" || tokens[pos] == "/" || tokens[pos] == "%") {
            let op = tokens[pos]
            pos += 1
            let rhs = parseConstUnary(tokens, &pos)
            if rhs == 0 {
                lhs = 0
            } else {
                switch op {
                case "*": lhs = lhs * rhs
                case "/": lhs = lhs / rhs
                case "%": lhs = lhs % rhs
                default: break
                }
            }
        }
        return lhs
    }
    
    private func parseConstUnary(_ tokens: [String], _ pos: inout Int) -> Int64 {
        if pos < tokens.count {
            let t = tokens[pos]
            if t == "!" {
                pos += 1
                return parseConstUnary(tokens, &pos) == 0 ? 1 : 0
            } else if t == "~" {
                pos += 1
                return ~parseConstUnary(tokens, &pos)
            } else if t == "-" {
                pos += 1
                return -parseConstUnary(tokens, &pos)
            } else if t == "+" {
                pos += 1
                return parseConstUnary(tokens, &pos)
            }
        }
        return parseConstPrimary(tokens, &pos)
    }
    
    private func parseConstPrimary(_ tokens: [String], _ pos: inout Int) -> Int64 {
        guard pos < tokens.count else { return 0 }
        let t = tokens[pos]
        pos += 1
        
        if t == "(" {
            let val = parseConstLogicalOr(tokens, &pos)
            if pos < tokens.count && tokens[pos] == ")" {
                pos += 1
            }
            return val
        }
        
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            return Int64(t.dropFirst(2), radix: 16) ?? 0
        }
        return Int64(t) ?? 0
    }
    
    // MARK: - Header & Include Processing
    
    private func processInclude(_ rawInclude: String, lineNum: Int, fileName: String) {
        var header = rawInclude.trimmingCharacters(in: .whitespaces)
        let isSystem = header.hasPrefix("<") && header.hasSuffix(">")
        let isUser = header.hasPrefix("\"") && header.hasSuffix("\"")
        
        if isSystem || isUser {
            header = String(header.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        
        let filePrefix = fileName.isEmpty ? "" : "\(fileName):\(lineNum): "
        
        if isUser {
            if let fileDirectory = fileDirectory {
                let candidateURL = fileDirectory.appendingPathComponent(header)
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    includedHeaders.insert(header)
                    return
                }
            }
            if isSupportedStandardHeader(header) {
                includedHeaders.insert(header)
                defineHeaderMacros(header)
                return
            }
            diagnostics.append("\(filePrefix)warning: header '\(header)' not found; skipping include.\n")
            return
        }
        
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
            "inttypes.h", "cinttypes",
            "stdarg.h", "cstdarg",
            "setjmp.h", "csetjmp",
            "signal.h", "csignal",
            "iso646.h", "ciso646",
            "wchar.h", "cwchar",
            "wctype.h", "cwctype",
            "uchar.h", "cuchar",
            "fenv.h", "cfenv",
            "tgmath.h", "ctgmath",
            "fcntl.h",
            "sys/types.h", "sys/stat.h", "sys/time.h",
            "iostream", "vector", "string", "algorithm",
            "utility", "memory", "map", "set", "sstream",
            "iomanip", "iterator", "stdexcept", "numeric",
            "functional", "chrono", "random", "tuple",
            "type_traits", "initializer_list", "list",
            "deque", "queue", "stack", "unordered_map",
            "unordered_set", "bitset", "fstream", "new",
            "exception", "system_error", "ratio", "regex",
            "atomic", "thread", "mutex", "condition_variable",
            "future", "string_view", "optional", "variant",
            "any", "filesystem", "complex", "valarray"
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
            macros["STDIN_FILENO"] = Macro(name: "STDIN_FILENO", parameters: nil, replacement: "0")
            macros["STDOUT_FILENO"] = Macro(name: "STDOUT_FILENO", parameters: nil, replacement: "1")
            macros["STDERR_FILENO"] = Macro(name: "STDERR_FILENO", parameters: nil, replacement: "2")
            macros["F_OK"] = Macro(name: "F_OK", parameters: nil, replacement: "0")
            macros["X_OK"] = Macro(name: "X_OK", parameters: nil, replacement: "1")
            macros["W_OK"] = Macro(name: "W_OK", parameters: nil, replacement: "2")
            macros["R_OK"] = Macro(name: "R_OK", parameters: nil, replacement: "4")
            macros["SEEK_SET"] = Macro(name: "SEEK_SET", parameters: nil, replacement: "0")
            macros["SEEK_CUR"] = Macro(name: "SEEK_CUR", parameters: nil, replacement: "1")
            macros["SEEK_END"] = Macro(name: "SEEK_END", parameters: nil, replacement: "2")
        case "stdlib.h", "cstdlib":
            macros["EXIT_SUCCESS"] = Macro(name: "EXIT_SUCCESS", parameters: nil, replacement: "0")
            macros["EXIT_FAILURE"] = Macro(name: "EXIT_FAILURE", parameters: nil, replacement: "1")
            macros["RAND_MAX"] = Macro(name: "RAND_MAX", parameters: nil, replacement: "2147483647")
        case "math.h", "cmath":
            macros["M_PI"] = Macro(name: "M_PI", parameters: nil, replacement: "3.141592653589793")
            macros["M_E"] = Macro(name: "M_E", parameters: nil, replacement: "2.718281828459045")
        case "time.h", "ctime":
            macros["CLOCKS_PER_SEC"] = Macro(name: "CLOCKS_PER_SEC", parameters: nil, replacement: "1000")
        case "stdio.h", "cstdio":
            macros["EOF"] = Macro(name: "EOF", parameters: nil, replacement: "-1")
            macros["BUFSIZ"] = Macro(name: "BUFSIZ", parameters: nil, replacement: "1024")
            macros["FILENAME_MAX"] = Macro(name: "FILENAME_MAX", parameters: nil, replacement: "1024")
        default:
            break
        }
    }
}
