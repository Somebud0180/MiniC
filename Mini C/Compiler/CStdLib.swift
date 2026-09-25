import Foundation

public protocol CRuntimeIO: AnyObject {
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
    func readStdin() async throws -> String
    var memory: MemoryManager { get }
}

public final class CStdLib {
    public static func registerBuiltins(
        runtimeIO: CRuntimeIO,
        builtins: inout [String: ([CValue]) async throws -> CValue]
    ) {
        // MARK: - stdio: printf
        builtins["printf"] = { args in
            guard let fmtArg = args.first else { return .int(0) }
            let formatString: String
            switch fmtArg {
            case .string(let s):
                formatString = s
            case .pointer(let addr):
                formatString = runtimeIO.memory.readCString(at: addr)
            default:
                formatString = fmtArg.description
            }
            
            let formatted = formatPrintf(format: formatString, args: Array(args.dropFirst()), memory: runtimeIO.memory)
            runtimeIO.writeStdout(formatted)
            return .int(Int64(formatted.count))
        }
        
        // MARK: - stdio: scanf
        builtins["scanf"] = { args in
            guard let fmtArg = args.first else { return .int(0) }
            let formatString: String
            switch fmtArg {
            case .string(let s): formatString = s
            case .pointer(let addr): formatString = runtimeIO.memory.readCString(at: addr)
            default: formatString = fmtArg.description
            }
            
            let pointerArgs = Array(args.dropFirst())
            return try await executeScanf(format: formatString, pointerArgs: pointerArgs, runtimeIO: runtimeIO)
        }
        
        // MARK: - stdio: puts
        builtins["puts"] = { args in
            let text: String
            if let first = args.first {
                switch first {
                case .string(let s): text = s
                case .pointer(let addr): text = runtimeIO.memory.readCString(at: addr)
                default: text = first.description
                }
            } else {
                text = ""
            }
            runtimeIO.writeStdout(text + "\n")
            return .int(Int64(text.count + 1))
        }
        
        // MARK: - stdio: getchar & putchar
        builtins["getchar"] = { _ in
            let input = try await runtimeIO.readStdin()
            if let firstChar = input.first?.asciiValue {
                return .int(Int64(firstChar))
            }
            return .int(-1) // EOF
        }
        
        builtins["putchar"] = { args in
            let chByte = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let str = String(Character(UnicodeScalar(chByte)))
            runtimeIO.writeStdout(str)
            return .int(Int64(chByte))
        }
        
        // MARK: - stdio: fflush
        builtins["fflush"] = { _ in
            return .int(0)
        }
        
        // MARK: - stdlib: malloc & free
        builtins["malloc"] = { args in
            let size = Int(args.first?.asInt ?? 0)
            let addr = runtimeIO.memory.allocateBlock(count: max(size, 1))
            return .pointer(addr)
        }
        
        builtins["free"] = { _ in
            return .void
        }
        
        // MARK: - stdlib: math
        builtins["abs"] = { args in
            return .int(abs(args.first?.asInt ?? 0))
        }
        builtins["labs"] = { args in
            return .int(abs(args.first?.asInt ?? 0))
        }
        builtins["sqrt"] = { args in
            return .double(sqrt(args.first?.asDouble ?? 0.0))
        }
        builtins["pow"] = { args in
            let base = args.first?.asDouble ?? 0.0
            let exp = args.count > 1 ? args[1].asDouble : 1.0
            return .double(pow(base, exp))
        }
        builtins["sin"] = { args in .double(sin(args.first?.asDouble ?? 0.0)) }
        builtins["cos"] = { args in .double(cos(args.first?.asDouble ?? 0.0)) }
        builtins["tan"] = { args in .double(tan(args.first?.asDouble ?? 0.0)) }
        builtins["floor"] = { args in .double(floor(args.first?.asDouble ?? 0.0)) }
        builtins["ceil"] = { args in .double(ceil(args.first?.asDouble ?? 0.0)) }
        builtins["round"] = { args in .double(round(args.first?.asDouble ?? 0.0)) }
        builtins["fabs"] = { args in .double(abs(args.first?.asDouble ?? 0.0)) }
        builtins["exp"] = { args in .double(exp(args.first?.asDouble ?? 0.0)) }
        builtins["log"] = { args in .double(log(args.first?.asDouble ?? 0.0)) }
        builtins["log10"] = { args in .double(log10(args.first?.asDouble ?? 0.0)) }
        builtins["hypot"] = { args in
            let x = args.first?.asDouble ?? 0.0
            let y = args.count > 1 ? args[1].asDouble : 0.0
            return .double(hypot(x, y))
        }
        
        // MARK: - stdlib: atoi, atof, rand
        builtins["atoi"] = { args in
            let str = args.first?.description ?? ""
            return .int(Int64(Int(str) ?? 0))
        }
        builtins["atof"] = { args in
            let str = args.first?.description ?? ""
            return .double(Double(str) ?? 0.0)
        }
        builtins["rand"] = { _ in
            return .int(Int64(arc4random_uniform(UInt32(Int32.max))))
        }
        builtins["srand"] = { _ in
            return .void
        }
        
        // MARK: - string.h
        builtins["strlen"] = { args in
            guard let first = args.first else { return .int(0) }
            let str: String
            switch first {
            case .string(let s): str = s
            case .pointer(let addr): str = runtimeIO.memory.readCString(at: addr)
            default: str = first.description
            }
            return .int(Int64(str.utf8.count))
        }
        
        builtins["strcmp"] = { args in
            guard args.count >= 2 else { return .int(0) }
            let s1 = (args[0] == .null) ? "" : ((casePointer(args[0], memory: runtimeIO.memory)))
            let s2 = (args[1] == .null) ? "" : ((casePointer(args[1], memory: runtimeIO.memory)))
            if s1 < s2 { return .int(-1) }
            if s1 > s2 { return .int(1) }
            return .int(0)
        }
        
        builtins["strcpy"] = { args in
            guard args.count >= 2 else { return .void }
            if case .pointer(let destAddr) = args[0] {
                let srcStr = casePointer(args[1], memory: runtimeIO.memory)
                runtimeIO.memory.writeCString(srcStr, to: destAddr)
                return .pointer(destAddr)
            }
            return .void
        }
        
        builtins["strcat"] = { args in
            guard args.count >= 2 else { return .void }
            if case .pointer(let destAddr) = args[0] {
                let destStr = runtimeIO.memory.readCString(at: destAddr)
                let srcStr = casePointer(args[1], memory: runtimeIO.memory)
                let combined = destStr + srcStr
                runtimeIO.memory.writeCString(combined, to: destAddr)
                return .pointer(destAddr)
            }
            return .void
        }
        
        // MARK: - ctype
        builtins["isalpha"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let isA = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            return .int(isA ? 1 : 0)
        }
        builtins["isdigit"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let isD = c >= 48 && c <= 57
            return .int(isD ? 1 : 0)
        }
        builtins["isalnum"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let isAlnum = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
            return .int(isAlnum ? 1 : 0)
        }
        builtins["toupper"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let up = (c >= 97 && c <= 122) ? c - 32 : c
            return .int(Int64(up))
        }
        builtins["tolower"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let low = (c >= 65 && c <= 90) ? c + 32 : c
            return .int(Int64(low))
        }
        
        // MARK: - time
        builtins["time"] = { _ in
            return .int(Int64(Date().timeIntervalSince1970))
        }
        builtins["clock"] = { _ in
            return .int(Int64(ProcessInfo.processInfo.systemUptime * 1000))
        }
        
        // MARK: - algorithm: min, max, swap
        builtins["max"] = { args in
            guard args.count >= 2 else { return args.first ?? .int(0) }
            return args[0].asDouble >= args[1].asDouble ? args[0] : args[1]
        }
        builtins["min"] = { args in
            guard args.count >= 2 else { return args.first ?? .int(0) }
            return args[0].asDouble <= args[1].asDouble ? args[0] : args[1]
        }
    }
    
    private static func casePointer(_ val: CValue, memory: MemoryManager) -> String {
        switch val {
        case .string(let s): return s
        case .pointer(let addr): return memory.readCString(at: addr)
        default: return val.description
        }
    }
    
    // MARK: - Printf Formatter
    
    public static func formatPrintf(format: String, args: [CValue], memory: MemoryManager) -> String {
        var output = ""
        var argIndex = 0
        var i = format.startIndex
        
        while i < format.endIndex {
            let ch = format[i]
            if ch == "%" {
                let nextIdx = format.index(after: i)
                if nextIdx >= format.endIndex {
                    output.append("%")
                    break
                }
                
                if format[nextIdx] == "%" {
                    output.append("%")
                    i = format.index(after: nextIdx)
                    continue
                }
                
                // Parse format specifiers e.g. %5d, %.2f, %02d, %s, %c, %x, %ld
                var specIndex = nextIdx
                var width: Int? = nil
                var precision: Int? = nil
                var isZeroPadded = false
                
                if specIndex < format.endIndex && format[specIndex] == "0" {
                    isZeroPadded = true
                    specIndex = format.index(after: specIndex)
                }
                
                // Width
                var widthStr = ""
                while specIndex < format.endIndex && format[specIndex].isNumber {
                    widthStr.append(format[specIndex])
                    specIndex = format.index(after: specIndex)
                }
                if let w = Int(widthStr) { width = w }
                
                // Precision
                if specIndex < format.endIndex && format[specIndex] == "." {
                    specIndex = format.index(after: specIndex)
                    var precStr = ""
                    while specIndex < format.endIndex && format[specIndex].isNumber {
                        precStr.append(format[specIndex])
                        specIndex = format.index(after: specIndex)
                    }
                    if let p = Int(precStr) { precision = p }
                }
                
                // Length modifiers (l, ll, h)
                while specIndex < format.endIndex && (format[specIndex] == "l" || format[specIndex] == "h") {
                    specIndex = format.index(after: specIndex)
                }
                
                if specIndex < format.endIndex {
                    let specChar = format[specIndex]
                    let arg = argIndex < args.count ? args[argIndex] : .int(0)
                    argIndex += 1
                    
                    var formattedArg = ""
                    switch specChar {
                    case "d", "i", "u":
                        let val = arg.asInt
                        if let w = width {
                            let pad = isZeroPadded ? "0" : " "
                            let raw = String(val)
                            formattedArg = raw.count < w ? String(repeating: pad, count: w - raw.count) + raw : raw
                        } else {
                            formattedArg = String(val)
                        }
                    case "f":
                        let val = arg.asDouble
                        let prec = precision ?? 6
                        let raw = String(format: "%.\(prec)f", val)
                        if let w = width, raw.count < w {
                            let pad = isZeroPadded ? "0" : " "
                            formattedArg = String(repeating: pad, count: w - raw.count) + raw
                        } else {
                            formattedArg = raw
                        }
                    case "g":
                        formattedArg = String(format: "%g", arg.asDouble)
                    case "s":
                        let str: String
                        switch arg {
                        case .string(let s): str = s
                        case .pointer(let addr): str = memory.readCString(at: addr)
                        default: str = arg.description
                        }
                        if let p = precision, str.count > p {
                            formattedArg = String(str.prefix(p))
                        } else {
                            formattedArg = str
                        }
                    case "c":
                        let byte = UInt8(arg.asInt & 0xFF)
                        formattedArg = String(Character(UnicodeScalar(byte)))
                    case "x":
                        formattedArg = String(format: "%llx", arg.asInt)
                    case "X":
                        formattedArg = String(format: "%llX", arg.asInt)
                    case "p":
                        formattedArg = String(format: "0x%llx", arg.asInt)
                    default:
                        formattedArg = "\(specChar)"
                    }
                    
                    output.append(formattedArg)
                    i = format.index(after: specIndex)
                    continue
                }
            }
            output.append(ch)
            i = format.index(after: i)
        }
        
        return output
    }
    
    // MARK: - Scanf Processor
    
    private static func executeScanf(
        format: String,
        pointerArgs: [CValue],
        runtimeIO: CRuntimeIO
    ) async throws -> CValue {
        var assignedCount = 0
        var argIndex = 0
        var formatIdx = format.startIndex
        
        while formatIdx < format.endIndex && argIndex < pointerArgs.count {
            let ch = format[formatIdx]
            if ch.isWhitespace {
                formatIdx = format.index(after: formatIdx)
                continue
            }
            
            if ch == "%" {
                formatIdx = format.index(after: formatIdx)
                if formatIdx >= format.endIndex { break }
                
                // Length modifier skip
                while formatIdx < format.endIndex && (format[formatIdx] == "l" || format[formatIdx] == "h") {
                    formatIdx = format.index(after: formatIdx)
                }
                guard formatIdx < format.endIndex else { break }
                let spec = format[formatIdx]
                formatIdx = format.index(after: formatIdx)
                
                // Request token from stdin
                let rawToken = try await runtimeIO.readStdin()
                let targetArg = pointerArgs[argIndex]
                argIndex += 1
                
                guard case .pointer(let targetAddr) = targetArg else { continue }
                
                switch spec {
                case "d", "i", "u":
                    if let intVal = Int64(rawToken.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        runtimeIO.memory.write(address: targetAddr, value: .int(intVal))
                        assignedCount += 1
                    }
                case "f":
                    if let dblVal = Double(rawToken.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        runtimeIO.memory.write(address: targetAddr, value: .double(dblVal))
                        assignedCount += 1
                    }
                case "s":
                    let strVal = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    runtimeIO.memory.writeCString(strVal, to: targetAddr)
                    assignedCount += 1
                case "c":
                    if let firstChar = rawToken.first?.asciiValue {
                        runtimeIO.memory.write(address: targetAddr, value: .char(firstChar))
                        assignedCount += 1
                    }
                default:
                    break
                }
            } else {
                formatIdx = format.index(after: formatIdx)
            }
        }
        
        return .int(Int64(assignedCount))
    }
}
