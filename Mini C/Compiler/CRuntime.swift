import Foundation

// MARK: - Runtime Values

public enum CValue: Equatable, Sendable, CustomStringConvertible {
    case int(Int64)
    case double(Double)
    case char(UInt8)
    case bool(Bool)
    case string(String)
    case pointer(Int) // Address in MemoryManager
    case structInstance(Int) // ID in MemoryManager
    case vectorInstance(Int) // ID in MemoryManager
    case null
    case void
    
    public var isDouble: Bool {
        if case .double = self { return true }
        return false
    }
    
    public var isPointer: Bool {
        if case .pointer = self { return true }
        return false
    }
    
    public var isString: Bool {
        if case .string = self { return true }
        return false
    }
    
    public var asInt: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .char(let v): return Int64(v)
        case .bool(let v): return v ? 1 : 0
        case .pointer(let v): return Int64(v)
        case .string(let s): return Int64(s) ?? 0
        case .null, .void, .structInstance, .vectorInstance: return 0
        }
    }
    
    public var asDouble: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .char(let v): return Double(v)
        case .bool(let v): return v ? 1.0 : 0.0
        case .pointer(let v): return Double(v)
        case .string(let s): return Double(s) ?? 0.0
        case .null, .void, .structInstance, .vectorInstance: return 0.0
        }
    }
    
    public var isTruthy: Bool {
        switch self {
        case .int(let v): return v != 0
        case .double(let v): return v != 0.0
        case .char(let v): return v != 0
        case .bool(let v): return v
        case .pointer(let v): return v != 0
        case .string(let s): return !s.isEmpty
        case .null, .void: return false
        case .structInstance, .vectorInstance: return true
        }
    }
    
    public var description: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let v):
            if v.truncatingRemainder(dividingBy: 1.0) == 0 {
                return String(format: "%.1f", v)
            }
            return String(v)
        case .char(let v): return String(Character(UnicodeScalar(v)))
        case .bool(let v): return v ? "true" : "false"
        case .string(let s): return s
        case .pointer(let addr): return addr == 0 ? "NULL" : String(format: "0x%llx", addr)
        case .structInstance(let id): return "<struct #\(id)>"
        case .vectorInstance(let id): return "<vector #\(id)>"
        case .null: return "NULL"
        case .void: return "void"
        }
    }
}

// MARK: - Memory Manager

public final class MemoryManager {
    private var memory: [Int: CValue] = [:]
    private var nextAddress: Int = 0x1000
    
    private var structs: [Int: [String: CValue]] = [:]
    private var nextStructId: Int = 1
    
    private var vectors: [Int: [CValue]] = [:]
    private var nextVectorId: Int = 1
    
    public init() {}
    
    public func reset() {
        memory.removeAll()
        nextAddress = 0x1000
        structs.removeAll()
        nextStructId = 1
        vectors.removeAll()
        nextVectorId = 1
    }
    
    public func allocate(value: CValue = .int(0)) -> Int {
        let addr = nextAddress
        nextAddress += 8
        memory[addr] = value
        return addr
    }
    
    public func allocateBlock(count: Int, defaultValue: CValue = .int(0)) -> Int {
        let baseAddr = nextAddress
        nextAddress += max(count * 8, 8)
        for i in 0..<count {
            memory[baseAddr + i * 8] = defaultValue
        }
        return baseAddr
    }
    
    public func read(address: Int) -> CValue {
        return memory[address] ?? .int(0)
    }
    
    public func write(address: Int, value: CValue) {
        memory[address] = value
    }
    
    // C-string reading and writing in simulated memory
    public func readCString(at address: Int) -> String {
        var addr = address
        var bytes: [UInt8] = []
        while true {
            guard let val = memory[addr] else { break }
            let b = UInt8(val.asInt & 0xFF)
            if b == 0 { break }
            bytes.append(b)
            addr += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    
    public func writeCString(_ str: String, to address: Int) {
        var addr = address
        for byte in str.utf8 {
            memory[addr] = .char(byte)
            addr += 1
        }
        memory[addr] = .char(0) // null terminator
    }
    
    // Structs
    public func createStruct(fields: [String: CValue]) -> Int {
        let id = nextStructId
        nextStructId += 1
        structs[id] = fields
        return id
    }
    
    public func getStructField(id: Int, name: String) -> CValue {
        return structs[id]?[name] ?? .int(0)
    }
    
    public func setStructField(id: Int, name: String, value: CValue) {
        if structs[id] != nil {
            structs[id]?[name] = value
        }
    }
    
    // Vectors
    public func createVector() -> Int {
        let id = nextVectorId
        nextVectorId += 1
        vectors[id] = []
        return id
    }
    
    public func vectorPushBack(id: Int, value: CValue) {
        vectors[id]?.append(value)
    }
    
    public func vectorPopBack(id: Int) {
        _ = vectors[id]?.popLast()
    }
    
    public func vectorSize(id: Int) -> Int {
        return vectors[id]?.count ?? 0
    }
    
    public func vectorGet(id: Int, index: Int) -> CValue {
        guard let vec = vectors[id], index >= 0, index < vec.count else { return .int(0) }
        return vec[index]
    }
    
    public func vectorSet(id: Int, index: Int, value: CValue) {
        if var vec = vectors[id], index >= 0, index < vec.count {
            vec[index] = value
            vectors[id] = vec
        }
    }
    
    public func vectorClear(id: Int) {
        vectors[id]?.removeAll()
    }
}

// MARK: - Scopes and Call Frames

public final class Scope {
    public let parent: Scope?
    public var variables: [String: Int] = [:] // Variable name -> Memory Address
    public var referenceTargets: [String: Int] = [:] // For C++ reference variables
    
    public init(parent: Scope? = nil) {
        self.parent = parent
    }
    
    public func define(name: String, address: Int) {
        variables[name] = address
    }
    
    public func defineReference(name: String, address: Int) {
        referenceTargets[name] = address
    }
    
    public func resolveAddress(name: String) -> Int? {
        if let refAddr = referenceTargets[name] {
            return refAddr
        }
        if let addr = variables[name] {
            return addr
        }
        return parent?.resolveAddress(name: name)
    }
}
