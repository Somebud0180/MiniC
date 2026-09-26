import Foundation

public enum CRuntimeControl: Error {
    case returnSignal(CValue)
    case breakSignal
    case continueSignal
    case exitSignal(Int)
}

public struct CRuntimeError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let location: SourceLocation?
    
    public init(_ message: String, location: SourceLocation? = nil) {
        self.message = message
        self.location = location
    }
    
    public var description: String {
        if let loc = location {
            return "Runtime Error [line \(loc.line)]: \(message)"
        }
        return "Runtime Error: \(message)"
    }
}

public final class CInterpreter: CRuntimeIO, @unchecked Sendable {
    public let memory: MemoryManager = MemoryManager()
    
    // I/O Callbacks
    public var onStdout: (@Sendable (String) -> Void)?
    public var onStderr: (@Sendable (String) -> Void)?
    public var onWaitingForInput: (@Sendable (Bool) -> Void)?
    
    // File & Library metadata
    public var fileName: String = ""
    public var includedHeaders: Set<String> = []
    private var warnedImplicitFunctions: Set<String> = []
    
    // Interactive STDIN queue & continuation
    private var stdinBuffer: [String] = []
    private var inputContinuation: CheckedContinuation<String, Error>? = nil
    private let lock = NSLock()
    
    // Scopes & Symbol Tables
    private var globalScope: Scope = Scope()
    private var currentScope: Scope
    private var functions: [String: (params: [(type: CType, name: String, isRef: Bool)], body: CStmt?)] = [:]
    private var builtins: [String: ([CValue]) async throws -> CValue] = [:]
    private var structs: [String: [(type: CType, name: String)]] = [:]
    
    // Watchdog
    private var stepCount: UInt64 = 0
    
    public init() {
        self.currentScope = self.globalScope
        CStdLib.registerBuiltins(runtimeIO: self, builtins: &builtins)
    }
    
    // MARK: - I/O Methods
    
    public func writeStdout(_ text: String) {
        onStdout?(text)
    }
    
    public func writeStderr(_ text: String) {
        onStderr?(text)
    }
    
    public func provideInput(_ text: String) {
        lock.lock()
        let tokens = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        if let continuation = inputContinuation {
            inputContinuation = nil
            onWaitingForInput?(false)
            if let first = tokens.first {
                let remainder = Array(tokens.dropFirst())
                stdinBuffer.append(contentsOf: remainder)
                lock.unlock()
                continuation.resume(returning: first)
                return
            } else {
                lock.unlock()
                continuation.resume(returning: text)
                return
            }
        } else {
            if tokens.isEmpty {
                stdinBuffer.append(text)
            } else {
                stdinBuffer.append(contentsOf: tokens)
            }
            lock.unlock()
        }
    }
    
    public func readStdin() async throws -> String {
        try Task.checkCancellation()
        
        let next: String? = lock.withLock {
            if !stdinBuffer.isEmpty {
                return stdinBuffer.removeFirst()
            }
            return nil
        }
        if let next {
            return next
        }
        
        onWaitingForInput?(true)
        
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.inputContinuation = continuation
            }
        }
    }
    
    public func cancel() {
        lock.lock()
        if let continuation = inputContinuation {
            inputContinuation = nil
            onWaitingForInput?(false)
            continuation.resume(throwing: CancellationError())
        }
        lock.unlock()
    }
    
    // MARK: - CRuntimeIO Function Invocation
    
    public func callFunction(name: String, args: [CValue]) async throws -> CValue {
        if let builtin = builtins[name] {
            return try await builtin(args)
        }
        guard let funcDef = functions[name] else {
            throw CRuntimeError("Function '\(name)' not found")
        }
        guard let body = funcDef.body else {
            throw CRuntimeError("Function '\(name)' has no body")
        }
        
        let funcScope = Scope(parent: globalScope)
        let funcNameAddr = memory.allocateCString(name)
        funcScope.define(name: "__func__", address: funcNameAddr, type: .pointer(.char))
        for (i, param) in funcDef.params.enumerated() {
            let val = i < args.count ? args[i] : .int(0)
            let addr = memory.allocate(value: val)
            funcScope.define(name: param.name, address: addr)
        }
        
        let prevScope = currentScope
        currentScope = funcScope
        defer { currentScope = prevScope }
        
        do {
            try await executeStatement(body)
            return .void
        } catch CRuntimeControl.returnSignal(let retVal) {
            return retVal
        }
    }
    
    // MARK: - Program Execution
    
    public func execute(program: CProgram) async throws -> Int {
        memory.reset()
        globalScope = Scope()
        currentScope = globalScope
        functions.removeAll()
        structs.removeAll()
        warnedImplicitFunctions.removeAll()
        stepCount = 0
        
        CStdLib.registerBuiltins(runtimeIO: self, builtins: &builtins)
        
        // Register top-level functions, structs, and global variables
        for decl in program.declarations {
            switch decl {
            case .funcDecl(_, let name, let params, let body, _):
                if let existing = functions[name], existing.body != nil && body == nil {
                    // Do not overwrite implemented function with prototype
                } else {
                    functions[name] = (params: params, body: body)
                }
            case .structDecl(let name, let fields, let isUnion, _):
                structs[name] = fields
                let layout = RecordLayoutEngine.computeLayout(fields: fields, isUnion: isUnion, structLayouts: memory.structLayouts)
                memory.structLayouts[name] = layout
            case .usingNamespace:
                break
            case .variableDecl:
                try await executeStatement(decl)
            default:
                break
            }
        }
        
        // Find and call main()
        guard let mainFunc = functions["main"] else {
            throw CRuntimeError("No 'main' function found in program.")
        }
        
        guard let mainBody = mainFunc.body else {
            throw CRuntimeError("'main' function has no body.")
        }
        
        let mainScope = Scope(parent: globalScope)
        let prevScope = currentScope
        currentScope = mainScope
        
        var exitCode: Int = 0
        do {
            try await executeStatement(mainBody)
            try await mainScope.unwind()
        } catch CRuntimeControl.returnSignal(let val) {
            try? await mainScope.unwind()
            exitCode = Int(val.asInt)
        } catch CRuntimeControl.exitSignal(let code) {
            try? await mainScope.unwind()
            exitCode = code
        } catch is CancellationError {
            try? await mainScope.unwind()
            writeStdout("\n[Program stopped by user]\n")
            return -1
        } catch {
            try? await mainScope.unwind()
            throw error
        }
        
        currentScope = prevScope
        return exitCode
    }
    
    // MARK: - Statement Execution
    
    private func checkWatchdog() async throws {
        stepCount += 1
        if stepCount % 1000 == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
    
    private func executeStatement(_ stmt: CStmt) async throws {
        try await checkWatchdog()
        
        switch stmt {
        case .block(let statements, _):
            let blockScope = Scope(parent: currentScope)
            let prevScope = currentScope
            currentScope = blockScope
            do {
                for s in statements {
                    try await executeStatement(s)
                }
                try await blockScope.unwind()
                currentScope = prevScope
            } catch {
                try? await blockScope.unwind()
                currentScope = prevScope
                throw error
            }
            
        case .variableDecl(let type, let name, let sizeExpr, let initExpr, let isConst, let location):
            if let sizeExpr = sizeExpr {
                let evaluatedSize = try await evaluate(sizeExpr).asInt
                let count = max(Int(evaluatedSize), 1)
                let elemType = type.pointeeType ?? .char
                let elemSize = elemType.abiSize
                let totalBytes = count * elemSize
                let addr = memory.allocateBlock(count: count, elementSize: elemSize)
                currentScope.define(name: name, address: addr, type: type, isConst: isConst)
                currentScope.setVLASize(name: name, size: totalBytes)
                return
            }
            if case .array(_, let arrCount) = type, let initExpr = initExpr {
                if case .literalString(let str, _) = initExpr {
                    let strBytes = Array(str.utf8)
                    let count = max(arrCount ?? (strBytes.count + 1), strBytes.count + 1)
                    let addr = memory.allocateBlock(count: count, elementSize: 1)
                    for (i, b) in strBytes.enumerated() {
                        memory.write(address: addr + i, value: .char(b))
                    }
                    memory.write(address: addr + strBytes.count, value: .char(0))
                    currentScope.define(name: name, address: addr, type: type, isConst: isConst)
                    return
                }
            }
            var initialValue: CValue = .int(0)
            if let initExpr = initExpr {
                if case .initializerList(let items, _) = initExpr {
                    switch type {
                    case .vectorType:
                        let vecId = memory.createVector()
                        for it in items {
                            let val = try await evaluate(it)
                            memory.vectorPushBack(id: vecId, value: val)
                        }
                        initialValue = .vectorInstance(vecId)
                    case .structType(let sName), .unionType(let sName):
                        var fieldMap: [String: CValue] = [:]
                        let fields = structs[sName] ?? []
                        for f in fields { fieldMap[f.name] = .int(0) }
                        var unnamedIdx = 0
                        for it in items {
                            if case .designatedInit(let fName, _, let valExpr, _) = it, let fName = fName {
                                fieldMap[fName] = try await evaluate(valExpr)
                            } else {
                                if unnamedIdx < fields.count {
                                    fieldMap[fields[unnamedIdx].name] = try await evaluate(it)
                                    unnamedIdx += 1
                                }
                            }
                        }
                        let (_, baseAddr) = memory.createStructInstance(name: sName, fields: fieldMap)
                        currentScope.define(name: name, address: baseAddr, type: type, isConst: isConst)
                        return
                    default:
                        // Array initialization
                        let elemType = type.pointeeType ?? .int
                        let elemSize = elemType.abiSize
                        let count: Int
                        if case .array(_, let explicitCount) = type, let c = explicitCount {
                            count = c
                        } else {
                            count = max(items.count, 1)
                        }
                        let addr = memory.allocateBlock(count: max(count, 1), elementSize: elemSize)
                        var nextIdx = 0
                        for it in items {
                            if case .designatedInit(_, let idxExpr, let valExpr, _) = it, let idxExpr = idxExpr {
                                let idxVal = Int(try await evaluate(idxExpr).asInt)
                                var v = try await evaluate(valExpr)
                                if elemType.isInteger {
                                    v = CValue.truncate(value: v.asInt, to: elemType)
                                }
                                memory.write(address: addr + idxVal * elemSize, value: v)
                                nextIdx = idxVal + 1
                            } else {
                                var v = try await evaluate(it)
                                if elemType.isInteger {
                                    v = CValue.truncate(value: v.asInt, to: elemType)
                                }
                                memory.write(address: addr + nextIdx * elemSize, value: v)
                                nextIdx += 1
                            }
                        }
                        currentScope.define(name: name, address: addr, type: type, isConst: isConst)
                        return
                    }
                } else {
                    initialValue = try await evaluate(initExpr)
                    if type.isInteger {
                        initialValue = CValue.truncate(value: initialValue.asInt, to: type)
                    }
                }
            } else {
                // Default value based on type
                switch type {
                case .vectorType:
                    let vecId = memory.createVector()
                    initialValue = .vectorInstance(vecId)
                case .mapType:
                    let mapId = memory.createMap()
                    initialValue = .mapInstance(mapId)
                case .stringType:
                    initialValue = .string("")
                case .structType(let sName), .unionType(let sName):
                    var fieldMap: [String: CValue] = [:]
                    if let fields = structs[sName] {
                        for f in fields { fieldMap[f.name] = .int(0) }
                    }
                    let (_, baseAddr) = memory.createStructInstance(name: sName, fields: fieldMap)
                    currentScope.define(name: name, address: baseAddr, type: type, isConst: isConst)
                    let ctorName = "\(sName)::\(sName)"
                    if functions[ctorName] != nil {
                        _ = try? await callFunction(name: ctorName, args: [])
                    }
                    currentScope.registerDestructor { [weak self] in
                        guard let self = self else { return }
                        let dtorName = "\(sName)::~"
                        if self.functions[dtorName] != nil {
                            _ = try? await self.callFunction(name: dtorName, args: [])
                        }
                    }
                    return
                case .array(let elem, let size):
                    let count = size ?? 10
                    let elemSize = elem.abiSize
                    let addr = memory.allocateBlock(count: count, elementSize: elemSize)
                    currentScope.define(name: name, address: addr, type: type, isConst: isConst)
                    return
                default:
                    initialValue = .int(0)
                }
            }
            
            // Check if variable is a C++ reference: int& ref = target;
            if case .reference = type {
                if let targetAddr = resolveLValueAddress(initExpr ?? .identifier(name, namespace: nil, location)) {
                    currentScope.defineReference(name: name, address: targetAddr, type: type)
                    return
                }
            }
            
            // Smart pointer copy retain
            if case .smartPointer(let spId) = initialValue {
                if let initExpr = initExpr, case .identifier(let origName, _, _) = initExpr {
                    if let origAddr = currentScope.resolveAddress(name: origName),
                       case .smartPointer = memory.read(address: origAddr) {
                        memory.retainSmartPointer(id: spId)
                    }
                }
                currentScope.registerDestructor { [weak self] in
                    guard let self = self else { return }
                    let (shouldDestroy, _, typeName) = self.memory.releaseSmartPointer(id: spId)
                    if shouldDestroy {
                        let dtorName = "\(typeName)::~"
                        if self.functions[dtorName] != nil {
                            _ = try? await self.callFunction(name: dtorName, args: [])
                        }
                    }
                }
            }
            
            let addr = memory.allocate(value: initialValue, alignment: type.abiAlignment, size: type.abiSize)
            currentScope.define(name: name, address: addr, type: type, isConst: isConst)
            if case .pointer(let inner) = type {
                if case .pointer(let pAddr) = initialValue {
                    memory.pointerPointeeSizes[pAddr] = inner.abiSize
                }
            }
            
        case .expr(let expr, _):
            _ = try await evaluate(expr)
            
        case .ifStmt(let cond, let thenStmt, let elseStmt, _):
            let condVal = try await evaluate(cond)
            if condVal.isTruthy {
                try await executeStatement(thenStmt)
            } else if let elseStmt = elseStmt {
                try await executeStatement(elseStmt)
            }
            
        case .whileStmt(let cond, let body, _):
            while true {
                try await checkWatchdog()
                let condVal = try await evaluate(cond)
                if !condVal.isTruthy { break }
                do {
                    try await executeStatement(body)
                } catch CRuntimeControl.breakSignal {
                    break
                } catch CRuntimeControl.continueSignal {
                    continue
                }
            }
            
        case .doWhileStmt(let body, let cond, _):
            while true {
                try await checkWatchdog()
                do {
                    try await executeStatement(body)
                } catch CRuntimeControl.breakSignal {
                    break
                } catch CRuntimeControl.continueSignal {
                    // proceed to condition check
                }
                let condVal = try await evaluate(cond)
                if !condVal.isTruthy { break }
            }
            
        case .forStmt(let initStmt, let condition, let stepExpr, let body, _):
            let forScope = Scope(parent: currentScope)
            let prevScope = currentScope
            currentScope = forScope
            defer { currentScope = prevScope }
            
            if let initStmt = initStmt {
                try await executeStatement(initStmt)
            }
            
            while true {
                try await checkWatchdog()
                if let condition = condition {
                    let condVal = try await evaluate(condition)
                    if !condVal.isTruthy { break }
                }
                
                do {
                    try await executeStatement(body)
                } catch CRuntimeControl.breakSignal {
                    break
                } catch CRuntimeControl.continueSignal {
                    // proceed to step
                }
                
                if let stepExpr = stepExpr {
                    _ = try await evaluate(stepExpr)
                }
            }
            
        case .switchStmt(let condition, let cases, _):
            let switchVal = try await evaluate(condition)
            var matched = false
            var defaultStmts: [CStmt]? = nil
            
            for (caseExpr, stmts) in cases {
                if let caseExpr = caseExpr {
                    let caseVal = try await evaluate(caseExpr)
                    if matched || caseVal.asInt == switchVal.asInt {
                        matched = true
                        do {
                            for s in stmts { try await executeStatement(s) }
                        } catch CRuntimeControl.breakSignal {
                            return
                        }
                    }
                } else {
                    defaultStmts = stmts
                }
            }
            
            if !matched, let defStmts = defaultStmts {
                do {
                    for s in defStmts { try await executeStatement(s) }
                } catch CRuntimeControl.breakSignal {
                    return
                }
            }
            
        case .returnStmt(let expr, _):
            var retVal: CValue = .void
            if let expr = expr {
                retVal = try await evaluate(expr)
            }
            throw CRuntimeControl.returnSignal(retVal)
            
        case .breakStmt:
            throw CRuntimeControl.breakSignal
            
        case .continueStmt:
            throw CRuntimeControl.continueSignal
            
        case .structDecl(let name, let fields, let isUnion, _):
            structs[name] = fields
            let layout = RecordLayoutEngine.computeLayout(fields: fields, isUnion: isUnion, structLayouts: memory.structLayouts)
            memory.structLayouts[name] = layout
            
        case .funcDecl(_, let name, let params, let body, _):
            if let existing = functions[name], existing.body != nil && body == nil {
            } else {
                functions[name] = (params: params, body: body)
            }
            
        case .usingNamespace:
            break
        }
    }
    
    // MARK: - Expression Evaluation
    
    public func evaluate(_ expr: CExpr) async throws -> CValue {
        try await checkWatchdog()
        
        switch expr {
        case .literalInt(let v, _): return .int(v)
        case .literalDouble(let v, _): return .double(v)
        case .literalChar(let v, _): return .char(v)
        case .literalString(let v, _): return .string(v)
        case .literalBool(let v, _): return .bool(v)
        case .literalNull: return .null
            
        case .identifier(let name, let ns, let loc):
            // Check for C++ std identifiers
            if ns == "std" || ns == nil {
                if name == "cout" { return .string("__std_cout__") }
                if name == "cin" { return .string("__std_cin__") }
                if name == "endl" { return .string("\n") }
                if name == "cerr" { return .string("__std_cerr__") }
            }
            
            let lookupName = (ns != nil && ns != "std") ? "\(ns!)::\(name)" : name
            guard let addr = currentScope.resolveAddress(name: lookupName) else {
                // Check if function pointer or name
                if functions[lookupName] != nil || builtins[lookupName] != nil || functions[name] != nil || builtins[name] != nil {
                    return .string(lookupName)
                }
                throw CRuntimeError("Undefined variable '\(lookupName)'", location: loc)
            }
            if let varType = currentScope.resolveType(name: lookupName), case .array = varType {
                return .pointer(addr)
            }
            if let sid = memory.addressToStructId[addr], let varType = currentScope.resolveType(name: lookupName) {
                switch varType {
                case .structType, .unionType: return .structInstance(sid)
                default: break
                }
            }
            return memory.read(address: addr)
            
        case .newExpr(let type, let args, _):
            let typeName: String
            switch type {
            case .structType(let sName), .custom(let sName): typeName = sName
            default: typeName = type.description
            }
            var fieldMap: [String: CValue] = [:]
            if let fields = structs[typeName] {
                for f in fields { fieldMap[f.name] = .int(0) }
            }
            let (_, baseAddr) = memory.createStructInstance(name: typeName, fields: fieldMap)
            let ctorName = "\(typeName)::\(typeName)"
            if functions[ctorName] != nil {
                var evalArgs: [CValue] = []
                for a in args { evalArgs.append(try await evaluate(a)) }
                _ = try await callFunction(name: ctorName, args: evalArgs)
            }
            return .pointer(baseAddr)
            
        case .lambda(let captures, let params, let body, _):
            var capturedMap: [String: CValue] = [:]
            for cap in captures {
                let cleanName = cap.hasPrefix("&") ? String(cap.dropFirst()) : cap
                if cleanName == "=" || cleanName == "&" { continue }
                if let addr = currentScope.resolveAddress(name: cleanName) {
                    capturedMap[cleanName] = memory.read(address: addr)
                }
            }
            let cid = memory.createClosure(captures: capturedMap, params: params, body: body)
            return .closure(cid)
            
        case .binary(let op, let leftExpr, let rightExpr, let loc):
            // C++ Stream insertion: cout << ...
            if op == .leftShift {
                let leftVal = try await evaluate(leftExpr)
                if case .string(let s) = leftVal, (s == "__std_cout__" || s == "__std_cerr__") {
                    let rightVal = try await evaluate(rightExpr)
                    let textToPrint: String
                    switch rightVal {
                    case .string(let text): textToPrint = text
                    case .char(let byte): textToPrint = String(Character(UnicodeScalar(byte)))
                    case .pointer(let addr): textToPrint = memory.readCString(at: addr)
                    default: textToPrint = rightVal.description
                    }
                    if s == "__std_cout__" {
                        writeStdout(textToPrint)
                    } else {
                        writeStderr(textToPrint)
                    }
                    return leftVal
                }
            }
            
            // C++ Stream extraction: cin >> var
            if op == .rightShift {
                let leftVal = try await evaluate(leftExpr)
                if case .string(let s) = leftVal, s == "__std_cin__" {
                    let inputToken = try await readStdin()
                    if let targetAddr = resolveLValueAddress(rightExpr) {
                        let currentVal = memory.read(address: targetAddr)
                        switch currentVal {
                        case .int:
                            let val = Int64(inputToken.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                            memory.write(address: targetAddr, value: .int(val))
                        case .double:
                            let val = Double(inputToken.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
                            memory.write(address: targetAddr, value: .double(val))
                        case .char:
                            let byte = inputToken.first?.asciiValue ?? 0
                            memory.write(address: targetAddr, value: .char(byte))
                        default:
                            memory.write(address: targetAddr, value: .string(inputToken))
                        }
                    }
                    return leftVal
                }
            }
            
            // Short-circuit logical operators
            if op == .logicalAnd {
                let leftVal = try await evaluate(leftExpr)
                if !leftVal.isTruthy { return .bool(false) }
                let rightVal = try await evaluate(rightExpr)
                return .bool(rightVal.isTruthy)
            }
            if op == .logicalOr {
                let leftVal = try await evaluate(leftExpr)
                if leftVal.isTruthy { return .bool(true) }
                let rightVal = try await evaluate(rightExpr)
                return .bool(rightVal.isTruthy)
            }
            
            let left = try await evaluate(leftExpr)
            let right = try await evaluate(rightExpr)
            return try evaluateBinaryOp(op: op, left: left, right: right, location: loc)
            
        case .unary(let op, let operand, let loc):
            return try await evaluateUnaryOp(op: op, operand: operand, location: loc)
            
        case .ternary(let cond, let thenExpr, let elseExpr, _):
            let c = try await evaluate(cond)
            if c.isTruthy {
                return try await evaluate(thenExpr)
            } else {
                return try await evaluate(elseExpr)
            }
            
        case .assignment(let op, let target, let valExpr, let loc):
            let value = try await evaluate(valExpr)
            return try await executeAssignment(op: op, target: target, value: value, location: loc)
            
        case .call(let callee, let argExprs, let loc):
            var args: [CValue] = []
            for argExpr in argExprs {
                args.append(try await evaluate(argExpr))
            }
            return try await executeCall(callee: callee, args: args, argExprs: argExprs, location: loc)
            
        case .subscriptAccess(let arrExpr, let indexExpr, let loc):
            let base = try await evaluate(arrExpr)
            switch base {
            case .mapInstance(let mid):
                let keyStr = try await evaluate(indexExpr).description
                return memory.mapGet(id: mid, key: keyStr) ?? .int(0)
            case .pointer(let baseAddr):
                let index = try await evaluate(indexExpr).asInt
                var pointeeSize = memory.pointerPointeeSizes[baseAddr] ?? 1
                if case .identifier(let arrName, _, _) = arrExpr,
                   let arrType = currentScope.resolveType(name: arrName),
                   let elemType = arrType.pointeeType {
                    pointeeSize = elemType.abiSize
                }
                return memory.read(address: baseAddr + Int(index) * pointeeSize)
            case .vectorInstance(let vid):
                let index = try await evaluate(indexExpr).asInt
                return memory.vectorGet(id: vid, index: Int(index))
            case .string(let s):
                let index = try await evaluate(indexExpr).asInt
                guard index >= 0, index < s.count else { return .char(0) }
                let charIdx = s.index(s.startIndex, offsetBy: Int(index))
                return .char(s[charIdx].asciiValue ?? 0)
            default:
                throw CRuntimeError("Cannot subscript non-array type", location: loc)
            }
            
        case .memberAccess(let objExpr, let member, let isArrow, let loc):
            var objVal = try await evaluate(objExpr)
            if isArrow {
                if case .pointer(let addr) = objVal {
                    if let sid = memory.addressToStructId[addr] {
                        objVal = .structInstance(sid)
                    } else {
                        let memVal = memory.read(address: addr)
                        if case .structInstance = memVal {
                            objVal = memVal
                        } else {
                            for layout in memory.structLayouts.values {
                                if let m = layout.memberMap[member] {
                                    if case .array = m.type {
                                        return .pointer(addr + m.offset)
                                    }
                                    return memory.read(address: addr + m.offset)
                                }
                            }
                        }
                    }
                }
            }
            
            // Check vector methods
            if case .vectorInstance(let vid) = objVal {
                if member == "size" { return .int(Int64(memory.vectorSize(id: vid))) }
                if member == "empty" { return .bool(memory.vectorSize(id: vid) == 0) }
                if member == "begin" { return .vectorIterator(vid: vid, index: 0) }
                if member == "end" { return .vectorIterator(vid: vid, index: memory.vectorSize(id: vid)) }
                if member == "front" { return memory.vectorGet(id: vid, index: 0) }
                if member == "back" { return memory.vectorGet(id: vid, index: max(0, memory.vectorSize(id: vid) - 1)) }
                if member == "rbegin" { return .vectorIterator(vid: vid, index: max(0, memory.vectorSize(id: vid) - 1)) }
                if member == "rend" { return .vectorIterator(vid: vid, index: -1) }
            }
            
            // Check string methods
            if case .string(let s) = objVal {
                if member == "length" || member == "size" { return .int(Int64(s.count)) }
                if member == "empty" { return .bool(s.isEmpty) }
                if member == "begin" { return .int(0) }
                if member == "end" { return .int(Int64(s.count)) }
                if member == "front" { return .char(s.utf8.first ?? 0) }
                if member == "back" { return .char(s.utf8.reversed().first ?? 0) }
            }
            
            // Check smart pointer methods
            if case .smartPointer(let spId) = objVal {
                if member == "use_count" {
                    return .int(Int64(memory.getSmartPointerRefCount(id: spId)))
                }
            }
            
            if case .structInstance(let sid) = objVal {
                return memory.getStructField(id: sid, name: member)
            }
            
            throw CRuntimeError("Cannot access member '\(member)'", location: loc)
            
        case .cast(let targetType, let expr, _):
            let val = try await evaluate(expr)
            if targetType.isInteger {
                return CValue.truncate(value: val.asInt, to: targetType)
            }
            switch targetType {
            case .float, .double: return .double(val.asDouble)
            case .char, .signedChar, .unsignedChar: return .char(UInt8(val.asInt & 0xFF))
            case .bool: return .bool(val.isTruthy)
            case .pointer(let inner):
                if case .pointer(let pAddr) = val {
                    memory.pointerPointeeSizes[pAddr] = inner.abiSize
                }
                return val
            default: return val
            }
            
        case .sizeofType(let type, _):
            if case .structType(let sName) = type, let layout = memory.structLayouts[sName] {
                return .int(Int64(layout.size))
            }
            if case .unionType(let sName) = type, let layout = memory.structLayouts[sName] {
                return .int(Int64(layout.size))
            }
            return .int(Int64(type.abiSize))
            
        case .sizeofExpr(let expr, _):
            if case .identifier(let name, _, _) = expr {
                if let vlaSize = currentScope.resolveVLASize(name: name) {
                    return .int(Int64(vlaSize))
                }
                if let type = currentScope.resolveType(name: name) {
                    if case .structType(let sName) = type, let layout = memory.structLayouts[sName] {
                        return .int(Int64(layout.size))
                    }
                    if case .unionType(let sName) = type, let layout = memory.structLayouts[sName] {
                        return .int(Int64(layout.size))
                    }
                    return .int(Int64(type.abiSize))
                }
            }
            let val = try await evaluate(expr)
            if case .string(let s) = val {
                return .int(Int64(s.utf8.count + 1))
            }
            return .int(8)
            
        case .designatedInit(_, _, let val, _):
            return try await evaluate(val)
            
        case .compoundLiteral(let type, let initExpr, _):
            switch type {
            case .structType(let sName), .unionType(let sName):
                var fieldMap: [String: CValue] = [:]
                let fields = structs[sName] ?? []
                for f in fields { fieldMap[f.name] = .int(0) }
                if case .initializerList(let items, _) = initExpr {
                    var unnamedIdx = 0
                    for it in items {
                        if case .designatedInit(let fName, _, let valExpr, _) = it, let fName = fName {
                            fieldMap[fName] = try await evaluate(valExpr)
                        } else {
                            if unnamedIdx < fields.count {
                                fieldMap[fields[unnamedIdx].name] = try await evaluate(it)
                                unnamedIdx += 1
                            }
                        }
                    }
                }
                let (_, baseAddr) = memory.createStructInstance(name: sName, fields: fieldMap)
                return .pointer(baseAddr)
            default:
                let elemType = type.pointeeType ?? .int
                let elemSize = elemType.abiSize
                var items: [CExpr] = []
                if case .initializerList(let it, _) = initExpr {
                    items = it
                }
                let count: Int
                if case .array(_, let explicitCount) = type, let c = explicitCount {
                    count = c
                } else {
                    count = max(items.count, 1)
                }
                let addr = memory.allocateBlock(count: max(count, 1), elementSize: elemSize)
                var nextIdx = 0
                for it in items {
                    if case .designatedInit(_, let idxExpr, let valExpr, _) = it, let idxExpr = idxExpr {
                        let idxVal = Int(try await evaluate(idxExpr).asInt)
                        var v = try await evaluate(valExpr)
                        if elemType.isInteger {
                            v = CValue.truncate(value: v.asInt, to: elemType)
                        }
                        memory.write(address: addr + idxVal * elemSize, value: v)
                        nextIdx = idxVal + 1
                    } else {
                        var v = try await evaluate(it)
                        if elemType.isInteger {
                            v = CValue.truncate(value: v.asInt, to: elemType)
                        }
                        memory.write(address: addr + nextIdx * elemSize, value: v)
                        nextIdx += 1
                    }
                }
                return .pointer(addr)
            }
            
        case .initializerList:
            return .int(0)
        }
    }
    
    // MARK: - Binary Evaluation
    
    private func evaluateBinaryOp(op: BinaryOperator, left: CValue, right: CValue, location: SourceLocation) throws -> CValue {
        switch op {
        case .add:
            if case .vectorIterator(let vid, let idx) = left {
                return .vectorIterator(vid: vid, index: idx + Int(right.asInt))
            }
            if case .string(let s1) = left {
                return .string(s1 + right.description)
            }
            if case .string(let s2) = right {
                return .string(left.description + s2)
            }
            // Pointer arithmetic: ptr + int (scaling by pointee size)
            if case .pointer(let addr) = left {
                let pointeeSize = memory.pointerPointeeSizes[addr] ?? 1
                return .pointer(addr + Int(right.asInt) * pointeeSize)
            }
            if case .pointer(let addr) = right {
                let pointeeSize = memory.pointerPointeeSizes[addr] ?? 1
                return .pointer(addr + Int(left.asInt) * pointeeSize)
            }
            if left.isDouble || right.isDouble {
                return .double(left.asDouble + right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .uint(left.asUInt &+ right.asUInt)
            }
            return .int(left.asInt + right.asInt)
            
        case .subtract:
            if case .vectorIterator(let vid, let idx) = left {
                if case .vectorIterator(_, let rIdx) = right {
                    return .int(Int64(idx - rIdx))
                }
                return .vectorIterator(vid: vid, index: idx - Int(right.asInt))
            }
            // Pointer difference: ptr - ptr (scaling by pointee size)
            if case .pointer(let a1) = left, case .pointer(let a2) = right {
                let pointeeSize = memory.pointerPointeeSizes[a1] ?? memory.pointerPointeeSizes[a2] ?? 1
                return .int(Int64((a1 - a2) / max(pointeeSize, 1)))
            }
            if case .pointer(let addr) = left {
                let pointeeSize = memory.pointerPointeeSizes[addr] ?? 1
                return .pointer(addr - Int(right.asInt) * pointeeSize)
            }
            if left.isDouble || right.isDouble {
                return .double(left.asDouble - right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .uint(left.asUInt &- right.asUInt)
            }
            return .int(left.asInt - right.asInt)
            
        case .multiply:
            if left.isDouble || right.isDouble {
                return .double(left.asDouble * right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .uint(left.asUInt &* right.asUInt)
            }
            return .int(left.asInt * right.asInt)
            
        case .divide:
            if left.isDouble || right.isDouble {
                if right.asDouble == 0 { throw CRuntimeError("Division by zero", location: location) }
                return .double(left.asDouble / right.asDouble)
            }
            if left.isUInt || right.isUInt {
                if right.asUInt == 0 { throw CRuntimeError("Division by zero", location: location) }
                return .uint(left.asUInt / right.asUInt)
            }
            if right.asInt == 0 { throw CRuntimeError("Division by zero", location: location) }
            return .int(left.asInt / right.asInt)
            
        case .modulo:
            if left.isUInt || right.isUInt {
                if right.asUInt == 0 { throw CRuntimeError("Modulo by zero", location: location) }
                return .uint(left.asUInt % right.asUInt)
            }
            if right.asInt == 0 { throw CRuntimeError("Modulo by zero", location: location) }
            return .int(left.asInt % right.asInt)
            
        case .equal:
            if case .vectorIterator(let v1, let i1) = left, case .vectorIterator(let v2, let i2) = right {
                return .bool(v1 == v2 && i1 == i2)
            }
            if case .mapIterator(_, _, let isEnd1) = left, case .mapIterator(_, _, let isEnd2) = right {
                return .bool(isEnd1 == isEnd2)
            }
            if case .string(let s1) = left, case .string(let s2) = right {
                return .bool(s1 == s2)
            }
            if left.isDouble || right.isDouble {
                return .bool(left.asDouble == right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .bool(left.asUInt == right.asUInt)
            }
            return .bool(left.asInt == right.asInt)
            
        case .notEqual:
            if case .vectorIterator(let v1, let i1) = left, case .vectorIterator(let v2, let i2) = right {
                return .bool(v1 != v2 || i1 != i2)
            }
            if case .mapIterator(_, _, let isEnd1) = left, case .mapIterator(_, _, let isEnd2) = right {
                return .bool(isEnd1 != isEnd2)
            }
            if case .string(let s1) = left, case .string(let s2) = right {
                return .bool(s1 != s2)
            }
            if left.isDouble || right.isDouble {
                return .bool(left.asDouble != right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .bool(left.asUInt != right.asUInt)
            }
            return .bool(left.asInt != right.asInt)
            
        case .less:
            if left.isDouble || right.isDouble {
                return .bool(left.asDouble < right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .bool(left.asUInt < right.asUInt)
            }
            return .bool(left.asInt < right.asInt)
            
        case .lessEqual:
            if left.isDouble || right.isDouble {
                return .bool(left.asDouble <= right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .bool(left.asUInt <= right.asUInt)
            }
            return .bool(left.asInt <= right.asInt)
            
        case .greater:
            if left.isDouble || right.isDouble {
                return .bool(left.asDouble > right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .bool(left.asUInt > right.asUInt)
            }
            return .bool(left.asInt > right.asInt)
            
        case .greaterEqual:
            if left.isDouble || right.isDouble {
                return .bool(left.asDouble >= right.asDouble)
            }
            if left.isUInt || right.isUInt {
                return .bool(left.asUInt >= right.asUInt)
            }
            return .bool(left.asInt >= right.asInt)
            
        case .bitwiseAnd:
            if left.isUInt || right.isUInt { return .uint(left.asUInt & right.asUInt) }
            return .int(left.asInt & right.asInt)
        case .bitwiseOr:
            if left.isUInt || right.isUInt { return .uint(left.asUInt | right.asUInt) }
            return .int(left.asInt | right.asInt)
        case .bitwiseXor:
            if left.isUInt || right.isUInt { return .uint(left.asUInt ^ right.asUInt) }
            return .int(left.asInt ^ right.asInt)
        case .leftShift:
            if left.isUInt || right.isUInt { return .uint(left.asUInt << right.asUInt) }
            return .int(left.asInt << right.asInt)
        case .rightShift:
            if left.isUInt || right.isUInt { return .uint(left.asUInt >> right.asUInt) }
            return .int(left.asInt >> right.asInt)
            
        case .logicalAnd, .logicalOr, .streamInsert, .streamExtract:
            return .void
        }
    }
    
    // MARK: - Unary Evaluation
    
    private func evaluateUnaryOp(op: UnaryOperator, operand: CExpr, location: SourceLocation) async throws -> CValue {
        switch op {
        case .plus:
            let val = try await evaluate(operand)
            return val
        case .negate:
            let val = try await evaluate(operand)
            if case .double(let d) = val { return .double(-d) }
            return .int(-val.asInt)
        case .logicalNot:
            let val = try await evaluate(operand)
            return .bool(!val.isTruthy)
        case .bitwiseNot:
            let val = try await evaluate(operand)
            return .int(~val.asInt)
        case .dereference:
            let val = try await evaluate(operand)
            if case .vectorIterator(let vid, let idx) = val {
                return memory.vectorGet(id: vid, index: idx)
            }
            if case .smartPointer(let spId) = val, let sp = memory.getSmartPointer(id: spId) {
                return memory.read(address: sp.innerAddr)
            }
            if case .string(let fnName) = val, (functions[fnName] != nil || builtins[fnName] != nil) {
                return val
            }
            guard case .pointer(let addr) = val else {
                throw CRuntimeError("Cannot dereference non-pointer value", location: location)
            }
            return memory.read(address: addr)
        case .addressOf:
            if case .identifier(let name, let ns, _) = operand {
                let lookupName = (ns != nil && ns != "std") ? "\(ns!)::\(name)" : name
                if currentScope.resolveAddress(name: lookupName) == nil && currentScope.resolveAddress(name: name) == nil {
                    if functions[lookupName] != nil || builtins[lookupName] != nil || functions[name] != nil || builtins[name] != nil {
                        return .string(lookupName)
                    }
                }
            }
            guard let addr = resolveLValueAddress(operand) else {
                throw CRuntimeError("lvalue required as unary '&' operand", location: location)
            }
            if case .identifier(let name, _, _) = operand, let t = currentScope.resolveType(name: name) {
                memory.pointerPointeeSizes[addr] = t.abiSize
            }
            return .pointer(addr)
        case .preInc:
            guard let addr = resolveLValueAddress(operand) else {
                throw CRuntimeError("Cannot increment non-variable", location: location)
            }
            let current = memory.read(address: addr)
            let updated = CValue.int(current.asInt + 1)
            memory.write(address: addr, value: updated)
            return updated
        case .postInc:
            guard let addr = resolveLValueAddress(operand) else {
                throw CRuntimeError("Cannot increment non-variable", location: location)
            }
            let current = memory.read(address: addr)
            let updated = CValue.int(current.asInt + 1)
            memory.write(address: addr, value: updated)
            return current
        case .preDec:
            guard let addr = resolveLValueAddress(operand) else {
                throw CRuntimeError("Cannot decrement non-variable", location: location)
            }
            let current = memory.read(address: addr)
            let updated = CValue.int(current.asInt - 1)
            memory.write(address: addr, value: updated)
            return updated
        case .postDec:
            guard let addr = resolveLValueAddress(operand) else {
                throw CRuntimeError("Cannot decrement non-variable", location: location)
            }
            let current = memory.read(address: addr)
            let updated = CValue.int(current.asInt - 1)
            memory.write(address: addr, value: updated)
            return current
        }
    }
    
    // MARK: - Assignment Execution
    
    private func executeAssignment(op: AssignmentOperator, target: CExpr, value: CValue, location: SourceLocation) async throws -> CValue {
        if case .identifier(let name, _, _) = target {
            if currentScope.isConst(name: name) {
                throw CRuntimeError("Cannot assign to variable '\(name)' with const-qualified type", location: location)
            }
        }
        
        // Struct member assignment
        if case .memberAccess(let objExpr, let member, let isArrow, _) = target {
            var objVal = try await evaluate(objExpr)
            if isArrow {
                if case .pointer(let addr) = objVal {
                    if let sid = memory.addressToStructId[addr] {
                        objVal = .structInstance(sid)
                    } else {
                        let memVal = memory.read(address: addr)
                        if case .structInstance = memVal {
                            objVal = memVal
                        } else {
                            for layout in memory.structLayouts.values {
                                if let m = layout.memberMap[member] {
                                    memory.write(address: addr + m.offset, value: value)
                                    return value
                                }
                            }
                        }
                    }
                }
            }
            if case .structInstance(let sid) = objVal {
                memory.setStructField(id: sid, name: member, value: value)
                return value
            }
        }
        
        // Array, vector, or map subscript assignment: arr[i] = val, map[key] = val
        if case .subscriptAccess(let arrExpr, let idxExpr, _) = target {
            let base = try await evaluate(arrExpr)
            if case .pointer(let addr) = base {
                let idx = try await evaluate(idxExpr).asInt
                var pointeeSize = memory.pointerPointeeSizes[addr] ?? 1
                if case .identifier(let arrName, _, _) = arrExpr,
                   let arrType = currentScope.resolveType(name: arrName),
                   let elemType = arrType.pointeeType {
                    pointeeSize = elemType.abiSize
                }
                memory.write(address: addr + Int(idx) * pointeeSize, value: value)
                return value
            } else if case .vectorInstance(let vid) = base {
                let idx = try await evaluate(idxExpr).asInt
                memory.vectorSet(id: vid, index: Int(idx), value: value)
                return value
            } else if case .mapInstance(let mid) = base {
                let keyStr = try await evaluate(idxExpr).description
                memory.mapSet(id: mid, key: keyStr, value: value)
                return value
            }
        }
        
        // Direct variable or pointer dereference assignment: *ptr = val or x = val
        guard let addr = resolveLValueAddress(target) else {
            throw CRuntimeError("Cannot assign to r-value", location: location)
        }
        
        let finalVal: CValue
        if op == .assign {
            finalVal = value
        } else {
            let cur = memory.read(address: addr)
            let binOp: BinaryOperator
            switch op {
            case .addAssign: binOp = .add
            case .subAssign: binOp = .subtract
            case .mulAssign: binOp = .multiply
            case .divAssign: binOp = .divide
            case .modAssign: binOp = .modulo
            case .andAssign: binOp = .bitwiseAnd
            case .orAssign: binOp = .bitwiseOr
            case .xorAssign: binOp = .bitwiseXor
            case .shlAssign: binOp = .leftShift
            case .shrAssign: binOp = .rightShift
            case .assign: binOp = .add
            }
            finalVal = try evaluateBinaryOp(op: binOp, left: cur, right: value, location: location)
        }
        
        memory.write(address: addr, value: finalVal)
        return finalVal
    }
    
    // MARK: - Closure Invocation
    
    private func executeClosure(cid: Int, args: [CValue], location: SourceLocation) async throws -> CValue {
        guard let closure = memory.getClosure(id: cid) else {
            throw CRuntimeError("Closure not found", location: location)
        }
        let callScope = Scope(parent: globalScope)
        for (k, v) in closure.captures {
            let addr = memory.allocate(value: v)
            callScope.define(name: k, address: addr)
        }
        for (i, param) in closure.params.enumerated() {
            let val = i < args.count ? args[i] : .int(0)
            let addr = memory.allocate(value: val)
            callScope.define(name: param.name, address: addr)
        }
        let prevScope = currentScope
        currentScope = callScope
        defer { currentScope = prevScope }
        do {
            try await executeStatement(closure.body)
            return .void
        } catch CRuntimeControl.returnSignal(let retVal) {
            return retVal
        }
    }
    
    // MARK: - Call Execution
    
    private func executeCall(callee: CExpr, args: [CValue], argExprs: [CExpr], location: SourceLocation) async throws -> CValue {
        // Vector, String, Map, or SmartPointer method call: v.push_back(...)
        if case .memberAccess(let objExpr, let member, _, _) = callee {
            let objVal = try await evaluate(objExpr)
            if case .vectorInstance(let vid) = objVal {
                if member == "push_back", let first = args.first {
                    memory.vectorPushBack(id: vid, value: first)
                    return .void
                }
                if member == "pop_back" {
                    memory.vectorPopBack(id: vid)
                    return .void
                }
                if member == "clear" {
                    memory.vectorClear(id: vid)
                    return .void
                }
                if member == "size" {
                    return .int(Int64(memory.vectorSize(id: vid)))
                }
                if member == "empty" {
                    return .bool(memory.vectorSize(id: vid) == 0)
                }
                if member == "begin" {
                    return .vectorIterator(vid: vid, index: 0)
                }
                if member == "end" {
                    return .vectorIterator(vid: vid, index: memory.vectorSize(id: vid))
                }
                if member == "erase", let first = args.first {
                    if case .vectorIterator(_, let idx) = first {
                        memory.vectorRemove(id: vid, at: idx)
                        return .vectorIterator(vid: vid, index: idx)
                    }
                }
            }
            if case .mapInstance(let mid) = objVal {
                if member == "find" {
                    let key = args.first?.description ?? ""
                    let contains = memory.mapContains(id: mid, key: key)
                    return .mapIterator(mid: mid, key: key, isEnd: !contains)
                }
                if member == "end" {
                    return .mapIterator(mid: mid, key: "", isEnd: true)
                }
                if member == "size" {
                    return .int(Int64(memory.mapCount(id: mid)))
                }
                if member == "empty" {
                    return .bool(memory.mapCount(id: mid) == 0)
                }
            }
            if case .string(var str) = objVal {
                if member == "push_back", let first = args.first {
                    let ch = Character(UnicodeScalar(UInt8(first.asInt & 0xFF)))
                    str.append(ch)
                    if let addr = resolveLValueAddress(objExpr) {
                        memory.write(address: addr, value: .string(str))
                    }
                    return .void
                }
                if member == "substr" {
                    let start = Int(args.first?.asInt ?? 0)
                    let len = args.count > 1 ? Int(args[1].asInt) : (str.count - start)
                    let sub = String(str.dropFirst(max(start, 0)).prefix(max(len, 0)))
                    return .string(sub)
                }
                if member == "length" || member == "size" {
                    return .int(Int64(str.count))
                }
            }
            if case .smartPointer(let spId) = objVal {
                if member == "use_count" {
                    return .int(Int64(memory.getSmartPointerRefCount(id: spId)))
                }
            }
        }
        
        // Closure variable call e.g. multiplier(5) or add(10, 20), or function pointer call
        var targetCallableName: String? = nil
        
        if case .identifier(let name, let ns, _) = callee {
            let directLookup = (ns != nil && ns != "std") ? "\(ns!)::\(name)" : name
            if let addr = currentScope.resolveAddress(name: directLookup) ?? currentScope.resolveAddress(name: name) {
                let val = memory.read(address: addr)
                if case .closure(let cid) = val {
                    return try await executeClosure(cid: cid, args: args, location: location)
                } else if case .string(let fnName) = val, (functions[fnName] != nil || builtins[fnName] != nil) {
                    targetCallableName = fnName
                }
            }
            if targetCallableName == nil {
                targetCallableName = directLookup
            }
        } else {
            // General expression call: (*fp)(...), (fp)(...), (lambda)(...), arr[i](...), etc.
            let calleeVal = try await evaluate(callee)
            if case .closure(let cid) = calleeVal {
                return try await executeClosure(cid: cid, args: args, location: location)
            } else if case .string(let fnName) = calleeVal, (functions[fnName] != nil || builtins[fnName] != nil) {
                targetCallableName = fnName
            } else if case .pointer(let addr) = calleeVal {
                let memVal = memory.read(address: addr)
                if case .closure(let cid) = memVal {
                    return try await executeClosure(cid: cid, args: args, location: location)
                } else if case .string(let fnName) = memVal, (functions[fnName] != nil || builtins[fnName] != nil) {
                    targetCallableName = fnName
                } else {
                    throw CRuntimeError("Expression is not callable", location: location)
                }
            } else {
                throw CRuntimeError("Expression is not callable", location: location)
            }
        }
        
        guard let lookupName = targetCallableName else {
            throw CRuntimeError("Expression is not callable", location: location)
        }
        
        // C++ Algorithms & Memory Builtins
        if lookupName == "sort" {
            guard args.count >= 2,
                  case .vectorIterator(let vid, let start) = args[0],
                  case .vectorIterator(_, let end) = args[1] else { return .void }
            var elems = memory.vectorElements(id: vid)
            if start < end && start >= 0 && end <= elems.count {
                let slice = elems[start..<end].sorted { $0.asInt < $1.asInt }
                elems.replaceSubrange(start..<end, with: slice)
                memory.vectorSetElements(id: vid, elements: elems)
            }
            return .void
        }
        
        if lookupName == "is_sorted" {
            guard args.count >= 2,
                  case .vectorIterator(let vid, let start) = args[0],
                  case .vectorIterator(_, let end) = args[1] else { return .bool(false) }
            let elems = memory.vectorElements(id: vid)
            var sorted = true
            if start < end && start >= 0 && end <= elems.count {
                for i in start..<(end - 1) {
                    if elems[i].asInt > elems[i + 1].asInt {
                        sorted = false
                        break
                    }
                }
            }
            return .bool(sorted)
        }
        
        if lookupName == "find" {
            guard args.count >= 3,
                  case .vectorIterator(let vid, let start) = args[0],
                  case .vectorIterator(_, let end) = args[1] else { return .null }
            let target = args[2]
            let elems = memory.vectorElements(id: vid)
            var foundIdx = end
            if start < end && start >= 0 && end <= elems.count {
                for i in start..<end {
                    if elems[i].asInt == target.asInt {
                        foundIdx = i
                        break
                    }
                }
            }
            return .vectorIterator(vid: vid, index: foundIdx)
        }
        
        if lookupName == "accumulate" {
            guard args.count >= 3,
                  case .vectorIterator(let vid, let start) = args[0],
                  case .vectorIterator(_, let end) = args[1] else { return .int(0) }
            var sum = args[2].asInt
            let elems = memory.vectorElements(id: vid)
            if start < end && start >= 0 && end <= elems.count {
                for i in start..<end {
                    sum += elems[i].asInt
                }
            }
            return .int(sum)
        }
        
        if lookupName == "make_shared" {
            let (_, baseAddr) = memory.createStructInstance(name: "Tracker", fields: [:])
            if functions["Tracker::Tracker"] != nil {
                _ = try await callFunction(name: "Tracker::Tracker", args: [])
            }
            let spId = memory.createSmartPointer(innerAddr: baseAddr, pointeeType: "Tracker", isShared: true)
            return .smartPointer(spId)
        }
        
        if lookupName == "unique_ptr" {
            let innerAddr = args.first?.asInt ?? 0
            let spId = memory.createSmartPointer(innerAddr: Int(innerAddr), pointeeType: "Tracker", isShared: false)
            return .smartPointer(spId)
        }
        
        if lookupName == "string" {
            if let first = args.first {
                if case .string(let s) = first {
                    return .string(s)
                }
                if case .pointer(let addr) = first {
                    return .string(memory.readCString(at: addr))
                }
            }
            return .string("")
        }
        
        // Builtin call
        if let builtin = builtins[lookupName] {
            checkHeaderInclusionForBuiltin(name: lookupName, location: location)
            return try await builtin(args)
        }
        
        // User function call
        guard let funcDef = functions[lookupName] else {
            let errorMsg = undeclaredFunctionError(name: lookupName, location: location)
            throw CRuntimeError(errorMsg, location: location)
        }
        
        guard let body = funcDef.body else {
            throw CRuntimeError("Function '\(lookupName)' has no definition", location: location)
        }
        
        let funcScope = Scope(parent: globalScope)
        let funcNameAddr = memory.allocateCString(lookupName)
        funcScope.define(name: "__func__", address: funcNameAddr, type: .pointer(.char))
        
        for (i, param) in funcDef.params.enumerated() {
            if param.isRef {
                // Pass-by-reference: bind parameter to original argument's memory address
                if i < argExprs.count, let argAddr = resolveLValueAddress(argExprs[i]) {
                    funcScope.defineReference(name: param.name, address: argAddr)
                } else {
                    let addr = memory.allocate(value: i < args.count ? args[i] : .int(0))
                    funcScope.define(name: param.name, address: addr)
                }
            } else {
                let val = i < args.count ? args[i] : .int(0)
                let addr = memory.allocate(value: val)
                funcScope.define(name: param.name, address: addr)
            }
        }
        
        let prevScope = currentScope
        currentScope = funcScope
        defer { currentScope = prevScope }
        
        do {
            try await executeStatement(body)
            return .void
        } catch CRuntimeControl.returnSignal(let returnVal) {
            return returnVal
        }
    }
    
    // MARK: - L-Value Address Resolution
    
    private func resolveLValueAddress(_ expr: CExpr) -> Int? {
        switch expr {
        case .identifier(let name, let ns, _):
            let lookupName = (ns != nil && ns != "std") ? "\(ns!)::\(name)" : name
            return currentScope.resolveAddress(name: lookupName)
        case .unary(.dereference, let operand, _):
            if case .identifier(let name, _, _) = operand,
               let addr = currentScope.resolveAddress(name: name) {
                let ptrVal = memory.read(address: addr)
                if case .pointer(let targetAddr) = ptrVal {
                    return targetAddr
                }
            }
            return nil
        case .subscriptAccess(let arrExpr, let idxExpr, _):
            if let baseAddr = resolveLValueAddress(arrExpr) {
                let ptrVal = memory.read(address: baseAddr)
                let actualBase: Int = ptrVal.isPointer ? Int(ptrVal.asInt) : baseAddr
                let step = memory.pointerPointeeSizes[actualBase] ?? memory.pointerPointeeSizes[baseAddr] ?? 8
                if case .literalInt(let idx, _) = idxExpr {
                    return actualBase + Int(idx) * step
                }
            }
            return nil
        case .memberAccess(let objExpr, let member, let isArrow, _):
            if isArrow {
                if let ptrAddr = resolveLValueAddress(objExpr) {
                    let ptrVal = memory.read(address: ptrAddr)
                    if case .pointer(let structBase) = ptrVal {
                        for layout in memory.structLayouts.values {
                            if let mem = layout.memberMap[member] {
                                return structBase + mem.offset
                            }
                        }
                    }
                }
            } else {
                if let structBase = resolveLValueAddress(objExpr) {
                    for layout in memory.structLayouts.values {
                        if let mem = layout.memberMap[member] {
                            return structBase + mem.offset
                        }
                    }
                }
            }
            return nil
        default:
            return nil
        }
    }
    
    // MARK: - Header & Undeclared Function Diagnostics
    
    private func checkHeaderInclusionForBuiltin(name: String, location: SourceLocation) {
        guard let requiredHeader = CStdLib.functionToHeader[name] else { return }
        let baseHeader = requiredHeader.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        let baseWithoutExt = baseHeader.hasSuffix(".h") ? String(baseHeader.dropLast(2)) : baseHeader
        
        let isIncluded = includedHeaders.contains(baseHeader) ||
                         includedHeaders.contains("<\(baseHeader)>") ||
                         includedHeaders.contains(baseWithoutExt) ||
                         includedHeaders.contains("<\(baseWithoutExt)>") ||
                         includedHeaders.contains("c\(baseWithoutExt)")
        
        if !isIncluded && !warnedImplicitFunctions.contains(name) {
            warnedImplicitFunctions.insert(name)
            let filePrefix = fileName.isEmpty ? "" : "\(fileName):\(location.line): "
            writeStderr("\(filePrefix)warning: implicit declaration of library function '\(name)'; did you forget to '#include \(requiredHeader)'?\n")
        }
    }
    
    private func undeclaredFunctionError(name: String, location: SourceLocation) -> String {
        // 1. Check if it's a known unsupported standard/POSIX function
        if let info = CStdLib.unsupportedStandardFunctions[name] {
            return "Call to undeclared function '\(name)'. Note: \(info.reason)."
        }
        
        // 2. Check if it's a known standard function from a library that was not included
        if let header = CStdLib.functionToHeader[name] {
            return "Call to undeclared function '\(name)'. Did you forget to #include \(header)?"
        }
        
        // 3. Typo suggestion against all builtins and declared functions
        let candidates: [String] = Array(builtins.keys) + Array(functions.keys)
        var bestMatch: String? = nil
        var minDistance = 3 // Only suggest if edit distance <= 2
        for candidate in candidates {
            let dist = levenshteinDistance(name, candidate)
            if dist < minDistance {
                minDistance = dist
                bestMatch = candidate
            }
        }
        if let match = bestMatch {
            return "Call to undeclared function '\(name)'. Did you mean '\(match)'?"
        }
        
        return "Call to undeclared function '\(name)'"
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        
        var dist = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    dist[i][j] = dist[i - 1][j - 1]
                } else {
                    dist[i][j] = min(dist[i - 1][j] + 1, dist[i][j - 1] + 1, dist[i - 1][j - 1] + 1)
                }
            }
        }
        return dist[a.count][b.count]
    }
}
