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
        builtins["time"] = { args in
            let now = Int64(Date().timeIntervalSince1970)
            if let first = args.first, case .pointer(let addr) = first, addr != 0 {
                runtimeIO.memory.write(address: addr, value: .int(now))
            }
            return .int(now)
        }
        builtins["clock"] = { _ in
            return .int(Int64(ProcessInfo.processInfo.systemUptime * 1000))
        }
        builtins["difftime"] = { args in
            let t1 = args.first?.asDouble ?? 0.0
            let t0 = args.count > 1 ? args[1].asDouble : 0.0
            return .double(t1 - t0)
        }
        builtins["ctime"] = { args in
            let t = args.first?.asInt ?? Int64(Date().timeIntervalSince1970)
            let date = Date(timeIntervalSince1970: TimeInterval(t))
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy\n"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let dateStr = formatter.string(from: date)
            let addr = runtimeIO.memory.allocateBlock(count: dateStr.utf8.count + 1)
            runtimeIO.memory.writeCString(dateStr, to: addr)
            return .pointer(addr)
        }

        // MARK: - unistd: sleep, usleep, pid, io, access
        builtins["sleep"] = { args in
            guard let first = args.first else {
                runtimeIO.writeStderr("warning: sleep() called without arguments\n")
                return .int(0)
            }
            let secs = first.asInt
            if secs < 0 {
                runtimeIO.writeStderr("warning: sleep() called with negative duration: \(secs)\n")
                return .int(0)
            }
            if secs > 0 {
                try await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            }
            return .int(0)
        }
        builtins["usleep"] = { args in
            guard let first = args.first else {
                runtimeIO.writeStderr("warning: usleep() called without arguments\n")
                return .int(0)
            }
            let usecs = first.asInt
            if usecs < 0 {
                runtimeIO.writeStderr("warning: usleep() called with negative duration: \(usecs)\n")
                return .int(0)
            }
            if usecs > 0 {
                try await Task.sleep(nanoseconds: UInt64(usecs) * 1_000)
            }
            return .int(0)
        }
        builtins["getpid"] = { _ in
            return .int(Int64(ProcessInfo.processInfo.processIdentifier))
        }
        builtins["getppid"] = { _ in
            return .int(1)
        }
        builtins["getuid"] = { _ in return .int(Int64(getuid())) }
        builtins["geteuid"] = { _ in return .int(Int64(geteuid())) }
        builtins["getgid"] = { _ in return .int(Int64(getgid())) }
        builtins["getegid"] = { _ in return .int(Int64(getegid())) }
        builtins["getcwd"] = { args in
            let cwd = FileManager.default.currentDirectoryPath
            if let first = args.first, case .pointer(let addr) = first, addr != 0 {
                let maxLen = args.count > 1 ? Int(args[1].asInt) : cwd.utf8.count + 1
                let truncated = String(cwd.prefix(max(maxLen - 1, 0)))
                runtimeIO.memory.writeCString(truncated, to: addr)
                return .pointer(addr)
            } else {
                let addr = runtimeIO.memory.allocateBlock(count: cwd.utf8.count + 1)
                runtimeIO.memory.writeCString(cwd, to: addr)
                return .pointer(addr)
            }
        }
        builtins["isatty"] = { args in
            let fd = args.first?.asInt ?? 0
            return .int(fd >= 0 && fd <= 2 ? 1 : 0)
        }
        builtins["access"] = { args in
            guard let first = args.first else { return .int(-1) }
            let path = casePointer(first, memory: runtimeIO.memory)
            return .int(FileManager.default.fileExists(atPath: path) ? 0 : -1)
        }
        builtins["alarm"] = { _ in return .int(0) }
        builtins["pause"] = { _ in
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return .int(-1)
        }
        builtins["read"] = { args in
            guard args.count >= 2, case .pointer(let bufAddr) = args[1] else { return .int(-1) }
            let fd = args[0].asInt
            guard fd == 0 else { return .int(-1) }
            let count = args.count > 2 ? Int(args[2].asInt) : 1024
            let input = try await runtimeIO.readStdin()
            let bytes = Array(input.utf8.prefix(count))
            for (i, byte) in bytes.enumerated() {
                runtimeIO.memory.write(address: bufAddr + i, value: .char(byte))
            }
            return .int(Int64(bytes.count))
        }
        builtins["write"] = { args in
            guard args.count >= 2 else { return .int(-1) }
            let fd = args[0].asInt
            let text: String
            switch args[1] {
            case .string(let s): text = s
            case .pointer(let addr): text = runtimeIO.memory.readCString(at: addr)
            default: text = args[1].description
            }
            let count = args.count > 2 ? min(Int(args[2].asInt), text.utf8.count) : text.utf8.count
            let sub = String(text.prefix(count))
            if fd == 1 {
                runtimeIO.writeStdout(sub)
                return .int(Int64(count))
            } else if fd == 2 {
                runtimeIO.writeStderr(sub)
                return .int(Int64(count))
            }
            return .int(-1)
        }
        builtins["close"] = { _ in return .int(0) }

        // MARK: - stdlib additions: exit, abort, calloc, realloc, getenv, system
        builtins["exit"] = { args in
            let code = Int(args.first?.asInt ?? 0)
            throw CRuntimeControl.exitSignal(code)
        }
        builtins["_exit"] = { args in
            let code = Int(args.first?.asInt ?? 0)
            throw CRuntimeControl.exitSignal(code)
        }
        builtins["abort"] = { _ in
            runtimeIO.writeStderr("Abort trap: 6\n")
            throw CRuntimeControl.exitSignal(134)
        }
        builtins["calloc"] = { args in
            let num = Int(args.first?.asInt ?? 0)
            let size = args.count > 1 ? Int(args[1].asInt) : 1
            let total = max(num * size, 1)
            let addr = runtimeIO.memory.allocateBlock(count: total, defaultValue: .int(0))
            return .pointer(addr)
        }
        builtins["realloc"] = { args in
            let newSize = args.count > 1 ? Int(args[1].asInt) : 0
            let newAddr = runtimeIO.memory.allocateBlock(count: max(newSize, 1))
            if let first = args.first, case .pointer(let oldAddr) = first, oldAddr != 0 {
                for i in 0..<max(newSize, 1) {
                    runtimeIO.memory.write(address: newAddr + i * 8, value: runtimeIO.memory.read(address: oldAddr + i * 8))
                }
            }
            return .pointer(newAddr)
        }
        builtins["getenv"] = { args in
            guard let first = args.first else { return .null }
            let key = casePointer(first, memory: runtimeIO.memory)
            if let val = ProcessInfo.processInfo.environment[key] {
                let addr = runtimeIO.memory.allocateBlock(count: val.utf8.count + 1)
                runtimeIO.memory.writeCString(val, to: addr)
                return .pointer(addr)
            }
            return .null
        }
        builtins["system"] = { args in
            runtimeIO.writeStderr("warning: system() shell invocation is sandboxed in Mini C\n")
            return .int(0)
        }

        // MARK: - stdio additions: sprintf, snprintf, perror, remove, rename
        builtins["sprintf"] = { args in
            guard args.count >= 2, case .pointer(let destAddr) = args[0] else { return .int(0) }
            let fmtStr = casePointer(args[1], memory: runtimeIO.memory)
            let formatted = formatPrintf(format: fmtStr, args: Array(args.dropFirst(2)), memory: runtimeIO.memory)
            runtimeIO.memory.writeCString(formatted, to: destAddr)
            return .int(Int64(formatted.utf8.count))
        }
        builtins["snprintf"] = { args in
            guard args.count >= 3, case .pointer(let destAddr) = args[0] else { return .int(0) }
            let maxSize = Int(args[1].asInt)
            let fmtStr = casePointer(args[2], memory: runtimeIO.memory)
            let formatted = formatPrintf(format: fmtStr, args: Array(args.dropFirst(3)), memory: runtimeIO.memory)
            let truncated = String(formatted.prefix(max(maxSize - 1, 0)))
            runtimeIO.memory.writeCString(truncated, to: destAddr)
            return .int(Int64(formatted.utf8.count))
        }
        builtins["perror"] = { args in
            let prefix = args.first != nil ? casePointer(args[0], memory: runtimeIO.memory) : ""
            let msg = prefix.isEmpty ? "Unknown error: 0\n" : "\(prefix): Success\n"
            runtimeIO.writeStderr(msg)
            return .void
        }
        builtins["remove"] = { args in
            guard let first = args.first else { return .int(-1) }
            let path = casePointer(first, memory: runtimeIO.memory)
            do {
                try FileManager.default.removeItem(atPath: path)
                return .int(0)
            } catch {
                return .int(-1)
            }
        }
        builtins["rename"] = { args in
            guard args.count >= 2 else { return .int(-1) }
            let p1 = casePointer(args[0], memory: runtimeIO.memory)
            let p2 = casePointer(args[1], memory: runtimeIO.memory)
            do {
                try FileManager.default.moveItem(atPath: p1, toPath: p2)
                return .int(0)
            } catch {
                return .int(-1)
            }
        }

        // MARK: - string additions
        builtins["strncmp"] = { args in
            guard args.count >= 2 else { return .int(0) }
            let s1 = casePointer(args[0], memory: runtimeIO.memory)
            let s2 = casePointer(args[1], memory: runtimeIO.memory)
            let n = args.count > 2 ? Int(args[2].asInt) : Int.max
            let p1 = String(s1.prefix(n))
            let p2 = String(s2.prefix(n))
            if p1 < p2 { return .int(-1) }
            if p1 > p2 { return .int(1) }
            return .int(0)
        }
        builtins["strncpy"] = { args in
            guard args.count >= 2, case .pointer(let destAddr) = args[0] else { return .void }
            let srcStr = casePointer(args[1], memory: runtimeIO.memory)
            let n = args.count > 2 ? Int(args[2].asInt) : srcStr.utf8.count
            let truncated = String(srcStr.prefix(n))
            runtimeIO.memory.writeCString(truncated, to: destAddr)
            return .pointer(destAddr)
        }
        builtins["strncat"] = { args in
            guard args.count >= 2, case .pointer(let destAddr) = args[0] else { return .void }
            let destStr = runtimeIO.memory.readCString(at: destAddr)
            let srcStr = casePointer(args[1], memory: runtimeIO.memory)
            let n = args.count > 2 ? Int(args[2].asInt) : srcStr.utf8.count
            let combined = destStr + String(srcStr.prefix(n))
            runtimeIO.memory.writeCString(combined, to: destAddr)
            return .pointer(destAddr)
        }
        builtins["strstr"] = { args in
            guard args.count >= 2 else { return .null }
            let hay = casePointer(args[0], memory: runtimeIO.memory)
            let needle = casePointer(args[1], memory: runtimeIO.memory)
            if needle.isEmpty { return args[0] }
            if let range = hay.range(of: needle) {
                let offset = hay.distance(from: hay.startIndex, to: range.lowerBound)
                if case .pointer(let addr) = args[0] {
                    return .pointer(addr + offset)
                }
                return .string(String(hay[range.lowerBound...]))
            }
            return .null
        }
        builtins["strchr"] = { args in
            guard args.count >= 2 else { return .null }
            let str = casePointer(args[0], memory: runtimeIO.memory)
            let targetChar = Character(UnicodeScalar(UInt8(args[1].asInt & 0xFF)))
            if let idx = str.firstIndex(of: targetChar) {
                let offset = str.distance(from: str.startIndex, to: idx)
                if case .pointer(let addr) = args[0] {
                    return .pointer(addr + offset)
                }
                return .string(String(str[idx...]))
            }
            return .null
        }
        builtins["strrchr"] = { args in
            guard args.count >= 2 else { return .null }
            let str = casePointer(args[0], memory: runtimeIO.memory)
            let targetChar = Character(UnicodeScalar(UInt8(args[1].asInt & 0xFF)))
            if let idx = str.lastIndex(of: targetChar) {
                let offset = str.distance(from: str.startIndex, to: idx)
                if case .pointer(let addr) = args[0] {
                    return .pointer(addr + offset)
                }
                return .string(String(str[idx...]))
            }
            return .null
        }
        builtins["memset"] = { args in
            guard args.count >= 3, case .pointer(let addr) = args[0] else { return args.first ?? .void }
            let byte = UInt8(args[1].asInt & 0xFF)
            let len = Int(args[2].asInt)
            for i in 0..<len {
                runtimeIO.memory.write(address: addr + i, value: .char(byte))
            }
            return .pointer(addr)
        }
        builtins["memcpy"] = { args in
            guard args.count >= 3, case .pointer(let dstAddr) = args[0], case .pointer(let srcAddr) = args[1] else { return args.first ?? .void }
            let n = Int(args[2].asInt)
            for i in 0..<n {
                let v = runtimeIO.memory.read(address: srcAddr + i)
                runtimeIO.memory.write(address: dstAddr + i, value: v)
            }
            return .pointer(dstAddr)
        }
        builtins["memcmp"] = { args in
            guard args.count >= 3, case .pointer(let a1) = args[0], case .pointer(let a2) = args[1] else { return .int(0) }
            let n = Int(args[2].asInt)
            for i in 0..<n {
                let b1 = runtimeIO.memory.read(address: a1 + i).asInt
                let b2 = runtimeIO.memory.read(address: a2 + i).asInt
                if b1 != b2 { return .int(b1 < b2 ? -1 : 1) }
            }
            return .int(0)
        }

        // MARK: - ctype additions
        builtins["isspace"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let isSp = c == 32 || (c >= 9 && c <= 13)
            return .int(isSp ? 1 : 0)
        }
        builtins["ispunct"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let isP = (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
            return .int(isP ? 1 : 0)
        }
        builtins["islower"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            return .int((c >= 97 && c <= 122) ? 1 : 0)
        }
        builtins["isupper"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            return .int((c >= 65 && c <= 90) ? 1 : 0)
        }
        builtins["isprint"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            return .int((c >= 32 && c <= 126) ? 1 : 0)
        }
        builtins["isxdigit"] = { args in
            let c = UInt8(args.first?.asInt ?? 0 & 0xFF)
            let isHex = (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
            return .int(isHex ? 1 : 0)
        }
        builtins["isascii"] = { args in
            let c = args.first?.asInt ?? 0
            return .int(c >= 0 && c <= 127 ? 1 : 0)
        }

        // MARK: - assert
        builtins["assert"] = { args in
            guard let cond = args.first else { return .void }
            if !cond.isTruthy {
                throw CRuntimeError("Assertion failed")
            }
            return .void
        }

        // MARK: - math additions
        builtins["asin"] = { args in .double(asin(args.first?.asDouble ?? 0.0)) }
        builtins["acos"] = { args in .double(acos(args.first?.asDouble ?? 0.0)) }
        builtins["atan"] = { args in .double(atan(args.first?.asDouble ?? 0.0)) }
        builtins["atan2"] = { args in
            let y = args.first?.asDouble ?? 0.0
            let x = args.count > 1 ? args[1].asDouble : 0.0
            return .double(atan2(y, x))
        }
        builtins["fmod"] = { args in
            let x = args.first?.asDouble ?? 0.0
            let y = args.count > 1 ? args[1].asDouble : 1.0
            return .double(fmod(x, y))
        }
        builtins["cbrt"] = { args in .double(cbrt(args.first?.asDouble ?? 0.0)) }
        builtins["log2"] = { args in .double(log2(args.first?.asDouble ?? 0.0)) }
        builtins["exp2"] = { args in .double(exp2(args.first?.asDouble ?? 0.0)) }

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
    
    // MARK: - Library Metadata for Diagnostics
    
    /// Maps builtin functions to their canonical standard header
    public static let functionToHeader: [String: String] = [
        // <unistd.h>
        "sleep": "<unistd.h>", "usleep": "<unistd.h>", "getpid": "<unistd.h>", "getppid": "<unistd.h>",
        "getuid": "<unistd.h>", "geteuid": "<unistd.h>", "getgid": "<unistd.h>", "getegid": "<unistd.h>",
        "getcwd": "<unistd.h>", "isatty": "<unistd.h>", "access": "<unistd.h>", "alarm": "<unistd.h>",
        "pause": "<unistd.h>", "read": "<unistd.h>", "write": "<unistd.h>", "close": "<unistd.h>",
        
        // <stdio.h>
        "printf": "<stdio.h>", "scanf": "<stdio.h>", "puts": "<stdio.h>", "getchar": "<stdio.h>",
        "putchar": "<stdio.h>", "sprintf": "<stdio.h>", "snprintf": "<stdio.h>", "perror": "<stdio.h>",
        "remove": "<stdio.h>", "rename": "<stdio.h>",
        
        // <stdlib.h>
        "malloc": "<stdlib.h>", "free": "<stdlib.h>", "calloc": "<stdlib.h>", "realloc": "<stdlib.h>",
        "exit": "<stdlib.h>", "_exit": "<stdlib.h>", "abort": "<stdlib.h>", "rand": "<stdlib.h>",
        "srand": "<stdlib.h>", "atoi": "<stdlib.h>", "atof": "<stdlib.h>", "abs": "<stdlib.h>",
        "labs": "<stdlib.h>", "getenv": "<stdlib.h>", "system": "<stdlib.h>",
        
        // <string.h>
        "strlen": "<string.h>", "strcmp": "<string.h>", "strncmp": "<string.h>", "strcpy": "<string.h>",
        "strncpy": "<string.h>", "strcat": "<string.h>", "strncat": "<string.h>", "strstr": "<string.h>",
        "strchr": "<string.h>", "strrchr": "<string.h>", "memset": "<string.h>", "memcpy": "<string.h>",
        "memcmp": "<string.h>",
        
        // <ctype.h>
        "isalpha": "<ctype.h>", "isdigit": "<ctype.h>", "isalnum": "<ctype.h>", "toupper": "<ctype.h>",
        "tolower": "<ctype.h>", "isspace": "<ctype.h>", "ispunct": "<ctype.h>", "islower": "<ctype.h>",
        "isupper": "<ctype.h>", "isprint": "<ctype.h>", "isxdigit": "<ctype.h>", "isascii": "<ctype.h>",
        
        // <math.h>
        "sqrt": "<math.h>", "pow": "<math.h>", "sin": "<math.h>", "cos": "<math.h>", "tan": "<math.h>",
        "asin": "<math.h>", "acos": "<math.h>", "atan": "<math.h>", "atan2": "<math.h>", "floor": "<math.h>",
        "ceil": "<math.h>", "round": "<math.h>", "fabs": "<math.h>", "fmod": "<math.h>", "cbrt": "<math.h>",
        "exp": "<math.h>", "exp2": "<math.h>", "log": "<math.h>", "log10": "<math.h>", "log2": "<math.h>",
        "hypot": "<math.h>",
        
        // <time.h>
        "time": "<time.h>", "clock": "<time.h>", "difftime": "<time.h>", "ctime": "<time.h>",
        
        // <assert.h>
        "assert": "<assert.h>"
    ]
    
    /// Maps known unsupported POSIX / standard C functions to explanatory notes
    public static let unsupportedStandardFunctions: [String: (header: String, reason: String)] = [
        "fork": ("<unistd.h>", "POSIX fork() cannot be executed in Mini C's sandbox environment"),
        "pipe": ("<unistd.h>", "POSIX pipe() is not supported in Mini C"),
        "exec": ("<unistd.h>", "Process execution functions are not supported in Mini C"),
        "execl": ("<unistd.h>", "Process execution functions are not supported in Mini C"),
        "execv": ("<unistd.h>", "Process execution functions are not supported in Mini C"),
        "execvp": ("<unistd.h>", "Process execution functions are not supported in Mini C"),
        "execve": ("<unistd.h>", "Process execution functions are not supported in Mini C"),
        "pthread_create": ("<pthread.h>", "POSIX multithreading (<pthread.h>) is not supported in Mini C"),
        "pthread_join": ("<pthread.h>", "POSIX multithreading (<pthread.h>) is not supported in Mini C"),
        "pthread_mutex_init": ("<pthread.h>", "POSIX threads are not supported in Mini C"),
        "pthread_mutex_lock": ("<pthread.h>", "POSIX threads are not supported in Mini C"),
        "pthread_mutex_unlock": ("<pthread.h>", "POSIX threads are not supported in Mini C"),
        "socket": ("<sys/socket.h>", "Berkeley sockets (<sys/socket.h>) are not supported in Mini C"),
        "connect": ("<sys/socket.h>", "Berkeley sockets are not supported in Mini C"),
        "bind": ("<sys/socket.h>", "Berkeley sockets are not supported in Mini C"),
        "listen": ("<sys/socket.h>", "Berkeley sockets are not supported in Mini C"),
        "accept": ("<sys/socket.h>", "Berkeley sockets are not supported in Mini C"),
        "send": ("<sys/socket.h>", "Berkeley sockets are not supported in Mini C"),
        "recv": ("<sys/socket.h>", "Berkeley sockets are not supported in Mini C"),
        "fopen": ("<stdio.h>", "File stream I/O (fopen) is not currently supported in Mini C runtime"),
        "fclose": ("<stdio.h>", "File stream I/O (fclose) is not currently supported in Mini C runtime"),
        "fread": ("<stdio.h>", "File stream I/O (fread) is not currently supported in Mini C runtime"),
        "fwrite": ("<stdio.h>", "File stream I/O (fwrite) is not currently supported in Mini C runtime"),
        "fseek": ("<stdio.h>", "File stream I/O is not currently supported in Mini C runtime"),
        "ftell": ("<stdio.h>", "File stream I/O is not currently supported in Mini C runtime"),
        "qsort": ("<stdlib.h>", "'qsort' is not currently implemented in Mini C. You can write a custom sorting function"),
        "bsearch": ("<stdlib.h>", "'bsearch' is not currently implemented in Mini C"),
        "kill": ("<signal.h>", "Signals (<signal.h>) are not supported in Mini C"),
        "signal": ("<signal.h>", "Signals (<signal.h>) are not supported in Mini C"),
        "sigaction": ("<signal.h>", "Signals (<signal.h>) are not supported in Mini C"),
        "mmap": ("<sys/mman.h>", "Memory mapping (<sys/mman.h>) is not supported in Mini C"),
        "munmap": ("<sys/mman.h>", "Memory mapping (<sys/mman.h>) is not supported in Mini C")
    ]
}
