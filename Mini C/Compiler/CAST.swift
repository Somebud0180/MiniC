import Foundation

// MARK: - Types

public indirect enum CType: Equatable, Sendable {
    case int
    case short
    case long
    case float
    case double
    case char
    case bool
    case void
    case pointer(CType)
    case reference(CType)
    case array(CType, Int?)
    case structType(String)
    case vectorType(CType)
    case stringType
    case custom(String)
    
    public var isNumeric: Bool {
        switch self {
        case .int, .short, .long, .float, .double, .char, .bool: return true
        default: return false
        }
    }
    
    public var isPointer: Bool {
        if case .pointer = self { return true }
        return false
    }
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
