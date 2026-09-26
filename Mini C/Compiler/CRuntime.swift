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
    
    public var asUInt: UInt64 {
        return UInt64(bitPattern: asInt)
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
    
    public static func truncate(value: Int64, to type: CType) -> CValue {
        switch type {
        case .char, .signedChar:
            return .int(Int64(Int8(truncatingIfNeeded: value)))
        case .unsignedChar:
            return .int(Int64(UInt8(truncatingIfNeeded: value)))
        case .short:
            return .int(Int64(Int16(truncatingIfNeeded: value)))
        case .unsignedShort:
            return .int(Int64(UInt16(truncatingIfNeeded: value)))
        case .int:
            return .int(Int64(Int32(truncatingIfNeeded: value)))
        case .unsignedInt:
            return .int(Int64(UInt32(truncatingIfNeeded: value)))
        case .bool:
            return .bool(value != 0)
        default:
            return .int(value)
        }
    }
}

// MARK: - Memory Manager (Byte-Aligned Layout & Standard ABI)

public final class MemoryManager {
    private var memory: [Int: CValue] = [:]
    private var nextAddress: Int = 0x1000
    
    public var structLayouts: [String: RecordLayout] = [:]
    private var structs: [Int: [String: CValue]] = [:]
    private var structAddresses: [Int: Int] = [:]
    private var addressToMember: [Int: (structId: Int, member: String)] = [:]
    private var nextStructId: Int = 1
    
    private var vectors: [Int: [CValue]] = [:]
    private var nextVectorId: Int = 1
    
    // Address -> element size for pointer arithmetic
    public var pointerPointeeSizes: [Int: Int] = [:]
    
    public init() {}
    
    public func reset() {
        memory.removeAll()
        nextAddress = 0x1000
        structs.removeAll()
        structAddresses.removeAll()
        addressToMember.removeAll()
        nextStructId = 1
        vectors.removeAll()
        nextVectorId = 1
        pointerPointeeSizes.removeAll()
    }
    
    public func alignNextAddress(to alignment: Int) {
        guard alignment > 0 else { return }
        let rem = nextAddress % alignment
        if rem != 0 {
            nextAddress += (alignment - rem)
        }
    }
    
    public func allocate(value: CValue = .int(0), alignment: Int = 8, size: Int = 8) -> Int {
        alignNextAddress(to: alignment)
        let addr = nextAddress
        nextAddress += max(size, 8)
        memory[addr] = value
        return addr
    }
    
    public func allocateBlock(count: Int, elementSize: Int = 8, defaultValue: CValue = .int(0)) -> Int {
        alignNextAddress(to: max(elementSize, 8))
        let baseAddr = nextAddress
        let step = max(elementSize, 8)
        nextAddress += max(count * step, step)
        for i in 0..<count {
            memory[baseAddr + i * step] = defaultValue
        }
        pointerPointeeSizes[baseAddr] = elementSize
        return baseAddr
    }
    
    public func read(address: Int) -> CValue {
        if let mapping = addressToMember[address] {
            return structs[mapping.structId]?[mapping.member] ?? .int(0)
        }
        return memory[address] ?? .int(0)
    }
    
    public func write(address: Int, value: CValue) {
        if let mapping = addressToMember[address] {
            if structs[mapping.structId] != nil {
                structs[mapping.structId]?[mapping.member] = value
            }
            return
        }
        memory[address] = value
    }
    
    // C-string reading and writing in memory
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
    
    // Standard Struct Layout Allocation
    public func createStructInstance(name: String, fields: [String: CValue]) -> (id: Int, address: Int) {
        let id = nextStructId
        nextStructId += 1
        structs[id] = fields
        
        let layout = structLayouts[name] ?? RecordLayout(size: 8, alignment: 8, members: [])
        alignNextAddress(to: layout.alignment)
        let baseAddr = nextAddress
        nextAddress += layout.size
        structAddresses[id] = baseAddr
        
        // Map member addresses
        for member in layout.members {
            let memberAddr = baseAddr + member.offset
            addressToMember[memberAddr] = (structId: id, member: member.name)
            if let val = fields[member.name] {
                memory[memberAddr] = val
            }
        }
        
        return (id, baseAddr)
    }
    
    public func createStruct(fields: [String: CValue]) -> Int {
        let (id, _) = createStructInstance(name: "", fields: fields)
        return id
    }
    
    public func getStructField(id: Int, name: String) -> CValue {
        return structs[id]?[name] ?? .int(0)
    }
    
    public func setStructField(id: Int, name: String, value: CValue) {
        if structs[id] != nil {
            structs[id]?[name] = value
            if let baseAddr = structAddresses[id],
               let layout = structLayouts.values.first(where: { $0.memberMap[name] != nil }),
               let member = layout.memberMap[name] {
                memory[baseAddr + member.offset] = value
            }
        }
    }
    
    public func getStructMemberAddress(id: Int, structName: String, memberName: String) -> Int? {
        guard let baseAddr = structAddresses[id] else { return nil }
        if let layout = structLayouts[structName], let member = layout.memberMap[memberName] {
            return baseAddr + member.offset
        }
        return nil
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
    public var variableTypes: [String: CType] = [:]
    public var constVariables: Set<String> = []
    public var referenceTargets: [String: Int] = [:] // For C++ reference variables
    private var destructors: [() async throws -> Void] = []
    
    public init(parent: Scope? = nil) {
        self.parent = parent
    }
    
    public func define(name: String, address: Int, type: CType = .int, isConst: Bool = false) {
        variables[name] = address
        variableTypes[name] = type
        if isConst {
            constVariables.insert(name)
        }
    }
    
    public func defineReference(name: String, address: Int, type: CType = .int) {
        referenceTargets[name] = address
        variableTypes[name] = type
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
    
    public func resolveType(name: String) -> CType? {
        if let t = variableTypes[name] {
            return t
        }
        return parent?.resolveType(name: name)
    }
    
    public func isConst(name: String) -> Bool {
        if constVariables.contains(name) { return true }
        return parent?.isConst(name: name) ?? false
    }
    
    public func registerDestructor(_ cleanup: @escaping () async throws -> Void) {
        destructors.append(cleanup)
    }
    
    public func unwind() async throws {
        // Execute destructors in LIFO (reverse declaration) order
        while !destructors.isEmpty {
            let dtor = destructors.removeLast()
            try await dtor()
        }
    }
}
