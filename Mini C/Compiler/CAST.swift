import Foundation

// MARK: - Type Qualifiers

public struct TypeQualifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    
    public static let const    = TypeQualifiers(rawValue: 1 << 0)
    public static let volatile = TypeQualifiers(rawValue: 1 << 1)
}

// MARK: - Types

public indirect enum CType: Equatable, Sendable {
    // Basic integer types
    case int
    case unsignedInt
    case short
    case unsignedShort
    case long
    case unsignedLong
    case longLong
    case unsignedLongLong
    
    // Floating point types
    case float
    case double
    
    // Character and Boolean types
    case char
    case signedChar
    case unsignedChar
    case bool
    case void
    
    // Derived types
    case pointer(CType)
    case reference(CType)
    case rvalueReference(CType)
    case array(CType, Int?)
    
    // User-defined / Composite
    case structType(String)
    case unionType(String)
    case vectorType(CType)
    case stringType
    case custom(String)
    
    public var isNumeric: Bool {
        switch self {
        case .int, .unsignedInt, .short, .unsignedShort,
             .long, .unsignedLong, .longLong, .unsignedLongLong,
             .float, .double, .char, .signedChar, .unsignedChar, .bool:
            return true
        default:
            return false
        }
    }
    
    public var isInteger: Bool {
        switch self {
        case .int, .unsignedInt, .short, .unsignedShort,
             .long, .unsignedLong, .longLong, .unsignedLongLong,
             .char, .signedChar, .unsignedChar, .bool:
            return true
        default:
            return false
        }
    }
    
    public var isFloatingPoint: Bool {
        return self == .float || self == .double
    }
    
    public var isSigned: Bool {
        switch self {
        case .unsignedInt, .unsignedShort, .unsignedLong, .unsignedLongLong, .unsignedChar, .bool:
            return false
        default:
            return true
        }
    }
    
    public var integerRank: Int {
        switch self {
        case .bool: return 1
        case .char, .signedChar, .unsignedChar: return 2
        case .short, .unsignedShort: return 3
        case .int, .unsignedInt: return 4
        case .long, .unsignedLong: return 5
        case .longLong, .unsignedLongLong: return 6
        default: return 0
        }
    }
    
    /// Standard LP64 ABI size in bytes (System V AMD64 / ARM64 AAPCS)
    public var abiSize: Int {
        switch self {
        case .bool, .char, .signedChar, .unsignedChar:
            return 1
        case .short, .unsignedShort:
            return 2
        case .int, .unsignedInt, .float:
            return 4
        case .long, .unsignedLong, .longLong, .unsignedLongLong, .double:
            return 8
        case .pointer, .reference, .rvalueReference:
            return 8
        case .array(let elem, let count):
            return (count ?? 1) * elem.abiSize
        case .void:
            return 0
        default:
            return 8
        }
    }
    
    /// Standard LP64 ABI alignment in bytes
    public var abiAlignment: Int {
        switch self {
        case .bool, .char, .signedChar, .unsignedChar:
            return 1
        case .short, .unsignedShort:
            return 2
        case .int, .unsignedInt, .float:
            return 4
        case .long, .unsignedLong, .longLong, .unsignedLongLong, .double:
            return 8
        case .pointer, .reference, .rvalueReference:
            return 8
        case .array(let elem, _):
            return elem.abiAlignment
        default:
            return 8
        }
    }
    
    public var isPointer: Bool {
        if case .pointer = self { return true }
        return false
    }
    
    public var isReference: Bool {
        switch self {
        case .reference, .rvalueReference: return true
        default: return false
        }
    }
    
    public var pointeeType: CType? {
        switch self {
        case .pointer(let p), .reference(let p), .rvalueReference(let p):
            return p
        case .array(let elem, _):
            return elem
        default:
            return nil
        }
    }
}

// MARK: - Type Promotion & Conversion Engine (ISO C99 §6.3.1)

public struct TypePromotionEngine {
    /// ISO C99 §6.3.1.1: Integer Promotion
    public static func promoteInteger(_ type: CType) -> CType {
        guard type.isInteger else { return type }
        if type.integerRank < CType.int.integerRank {
            return .int
        }
        return type
    }
    
    /// ISO C99 §6.3.1.8 / C++17 [expr.type]: Usual Arithmetic Conversions
    public static func usualArithmeticConversions(lhs: CType, rhs: CType) -> CType {
        // 1. If either operand is double, convert to double
        if lhs == .double || rhs == .double { return .double }
        if lhs == .float || rhs == .float { return .float }
        
        // 2. Both operands are integers: perform integer promotion
        let pLhs = promoteInteger(lhs)
        let pRhs = promoteInteger(rhs)
        
        if pLhs == pRhs { return pLhs }
        
        let lRank = pLhs.integerRank
        let rRank = pRhs.integerRank
        let lSigned = pLhs.isSigned
        let rSigned = pRhs.isSigned
        
        // Both have same signedness
        if lSigned == rSigned {
            return lRank >= rRank ? pLhs : pRhs
        }
        
        // Operands have different signedness
        let (uType, uRank) = lSigned ? (pRhs, rRank) : (pLhs, lRank)
        let (sType, sRank) = lSigned ? (pLhs, lRank) : (pRhs, rRank)
        
        // If unsigned operand has rank >= signed operand, convert signed to unsigned
        if uRank >= sRank {
            return uType
        }
        
        // Signed operand has strictly greater rank: in LP64, signed type represents all values
        return sType
    }
}

// MARK: - Standard ABI Record Layout Engine

public struct StructMemberLayout: Sendable {
    public let name: String
    public let type: CType
    public let offset: Int
    public let size: Int
    public let alignment: Int
    
    public init(name: String, type: CType, offset: Int, size: Int, alignment: Int) {
        self.name = name
        self.type = type
        self.offset = offset
        self.size = size
        self.alignment = alignment
    }
}

public struct RecordLayout: Sendable {
    public let size: Int
    public let alignment: Int
    public let members: [StructMemberLayout]
    public let memberMap: [String: StructMemberLayout]
    
    public init(size: Int, alignment: Int, members: [StructMemberLayout]) {
        self.size = size
        self.alignment = alignment
        self.members = members
        var map: [String: StructMemberLayout] = [:]
        for m in members {
            map[m.name] = m
        }
        self.memberMap = map
    }
}

public final class RecordLayoutEngine {
    public static func alignTo(_ offset: Int, _ alignment: Int) -> Int {
        guard alignment > 0 else { return offset }
        let remainder = offset % alignment
        return remainder == 0 ? offset : offset + (alignment - remainder)
    }
    
    public static func computeLayout(
        fields: [(type: CType, name: String)],
        isUnion: Bool = false,
        structLayouts: [String: RecordLayout] = [:]
    ) -> RecordLayout {
        var currentOffset = 0
        var maxAlignment = 1
        var memberLayouts: [StructMemberLayout] = []
        var maxMemberSize = 0
        
        for (type, name) in fields {
            let fieldSize: Int
            let fieldAlign: Int
            
            switch type {
            case .structType(let sName), .unionType(let sName):
                if let layout = structLayouts[sName] {
                    fieldSize = layout.size
                    fieldAlign = layout.alignment
                } else {
                    fieldSize = 8
                    fieldAlign = 8
                }
            default:
                fieldSize = type.abiSize
                fieldAlign = type.abiAlignment
            }
            
            maxAlignment = max(maxAlignment, fieldAlign)
            
            if isUnion {
                memberLayouts.append(StructMemberLayout(
                    name: name, type: type, offset: 0, size: fieldSize, alignment: fieldAlign
                ))
                maxMemberSize = max(maxMemberSize, fieldSize)
            } else {
                currentOffset = alignTo(currentOffset, fieldAlign)
                memberLayouts.append(StructMemberLayout(
                    name: name, type: type, offset: currentOffset, size: fieldSize, alignment: fieldAlign
                ))
                currentOffset += fieldSize
            }
        }
        
        let finalSize: Int
        if isUnion {
            finalSize = alignTo(maxMemberSize, maxAlignment)
        } else {
            finalSize = alignTo(currentOffset, maxAlignment)
        }
        
        return RecordLayout(size: max(finalSize, 1), alignment: maxAlignment, members: memberLayouts)
    }
}

// MARK: - Value Categories

public enum ValueCategory: Sendable {
    case lvalue
    case xvalue
    case prvalue
    
    public var isGlvalue: Bool { self == .lvalue || self == .xvalue }
    public var isRvalue: Bool { self == .prvalue || self == .xvalue }
}

// MARK: - Operators

public enum BinaryOperator: String, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case modulo = "%"
    
    case equal = "=="
    case notEqual = "!="
    case less = "<"
    case lessEqual = "<="
    case greater = ">"
    case greaterEqual = ">="
    
    case logicalAnd = "&&"
    case logicalOr = "||"
    
    case bitwiseAnd = "&"
    case bitwiseOr = "|"
    case bitwiseXor = "^"
    case leftShift = "<<"
    case rightShift = ">>"
    
    case streamInsert = "stream<<"
    case streamExtract = "stream>>"
}

public enum UnaryOperator: String, Sendable {
    case plus = "+"
    case negate = "-"
    case logicalNot = "!"
    case bitwiseNot = "~"
    case dereference = "*"
    case addressOf = "&"
    case preInc = "++prefix"
    case postInc = "++postfix"
    case preDec = "--prefix"
    case postDec = "--postfix"
}

public enum AssignmentOperator: String, Sendable {
    case assign = "="
    case addAssign = "+="
    case subAssign = "-="
    case mulAssign = "*="
    case divAssign = "/="
    case modAssign = "%="
    case andAssign = "&="
    case orAssign = "|="
    case xorAssign = "^="
    case shlAssign = "<<="
    case shrAssign = ">>="
}

// MARK: - Expressions

public indirect enum CExpr: Sendable {
    case literalInt(Int64, SourceLocation)
    case literalDouble(Double, SourceLocation)
    case literalChar(UInt8, SourceLocation)
    case literalString(String, SourceLocation)
    case literalBool(Bool, SourceLocation)
    case literalNull(SourceLocation)
    
    case identifier(String, namespace: String?, SourceLocation)
    case binary(BinaryOperator, CExpr, CExpr, SourceLocation)
    case unary(UnaryOperator, CExpr, SourceLocation)
    case ternary(CExpr, CExpr, CExpr, SourceLocation)
    case assignment(AssignmentOperator, CExpr, CExpr, SourceLocation)
    case call(CExpr, [CExpr], SourceLocation)
    case subscriptAccess(CExpr, CExpr, SourceLocation)
    case memberAccess(CExpr, String, isArrow: Bool, SourceLocation)
    case cast(CType, CExpr, SourceLocation)
    case sizeofType(CType, SourceLocation)
    case sizeofExpr(CExpr, SourceLocation)
    case initializerList([CExpr], SourceLocation)
    
    public var location: SourceLocation {
        switch self {
        case .literalInt(_, let loc),
             .literalDouble(_, let loc),
             .literalChar(_, let loc),
             .literalString(_, let loc),
             .literalBool(_, let loc),
             .literalNull(let loc),
             .identifier(_, _, let loc),
             .binary(_, _, _, let loc),
             .unary(_, _, let loc),
             .ternary(_, _, _, let loc),
             .assignment(_, _, _, let loc),
             .call(_, _, let loc),
             .subscriptAccess(_, _, let loc),
             .memberAccess(_, _, _, let loc),
             .cast(_, _, let loc),
             .sizeofType(_, let loc),
             .sizeofExpr(_, let loc),
             .initializerList(_, let loc):
            return loc
        }
    }
}

// MARK: - Statements

public indirect enum CStmt: Sendable {
    case block([CStmt], SourceLocation)
    case variableDecl(type: CType, name: String, initExpr: CExpr?, isConst: Bool, SourceLocation)
    case expr(CExpr, SourceLocation)
    case ifStmt(condition: CExpr, thenStmt: CStmt, elseStmt: CStmt?, SourceLocation)
    case whileStmt(condition: CExpr, body: CStmt, SourceLocation)
    case doWhileStmt(body: CStmt, condition: CExpr, SourceLocation)
    case forStmt(initStmt: CStmt?, condition: CExpr?, stepExpr: CExpr?, body: CStmt, SourceLocation)
    case switchStmt(condition: CExpr, cases: [(CExpr?, [CStmt])], SourceLocation)
    case returnStmt(CExpr?, SourceLocation)
    case breakStmt(SourceLocation)
    case continueStmt(SourceLocation)
    case structDecl(name: String, fields: [(type: CType, name: String)], location: SourceLocation)
    case funcDecl(returnType: CType, name: String, params: [(type: CType, name: String, isRef: Bool)], body: CStmt?, SourceLocation)
    case usingNamespace(String, SourceLocation)
    
    public var location: SourceLocation {
        switch self {
        case .block(_, let loc),
             .variableDecl(_, _, _, _, let loc),
             .expr(_, let loc),
             .ifStmt(_, _, _, let loc),
             .whileStmt(_, _, let loc),
             .doWhileStmt(_, _, let loc),
             .forStmt(_, _, _, _, let loc),
             .switchStmt(_, _, let loc),
             .returnStmt(_, let loc),
             .breakStmt(let loc),
             .continueStmt(let loc),
             .structDecl(_, _, let loc),
             .funcDecl(_, _, _, _, let loc),
             .usingNamespace(_, let loc):
            return loc
        }
    }
}

public struct CProgram: Sendable {
    public let declarations: [CStmt]
    
    public init(declarations: [CStmt]) {
        self.declarations = declarations
    }
}
