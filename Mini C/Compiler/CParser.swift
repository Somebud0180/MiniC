import Foundation

public struct CCompilerError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let location: SourceLocation
    
    public init(_ message: String, location: SourceLocation) {
        self.message = message
        self.location = location
    }
    
    public var description: String {
        "line \(location.line), column \(location.column): \(message)"
    }
}

public final class CParser {
    private let tokens: [CToken]
    private var current: Int = 0
    private var typedefs: Set<String> = []
    private var structNames: Set<String> = []
    private var extraTopDeclarations: [CStmt] = []
    
    public init(tokens: [CToken]) {
        self.tokens = tokens
    }
    
    private var isAtEnd: Bool {
        peek().type == .eof
    }
    
    private func peek() -> CToken {
        tokens[current]
    }
    
    private func previous() -> CToken {
        tokens[current - 1]
    }
    
    @discardableResult
    private func advance() -> CToken {
        if !isAtEnd { current += 1 }
        return previous()
    }
    
    private func check(_ type: CTokenType) -> Bool {
        if isAtEnd { return false }
        return peek().type == type
    }
    
    private func match(_ types: CTokenType...) -> Bool {
        for type in types {
            if check(type) {
                advance()
                return true
            }
        }
        return false
    }
    
    @discardableResult
    private func consume(_ type: CTokenType, message: String) throws -> CToken {
        if check(type) { return advance() }
        throw CCompilerError(message, location: peek().location)
    }
    
    // MARK: - Program Parsing
    
    public func parse() throws -> CProgram {
        var declarations: [CStmt] = []
        extraTopDeclarations.removeAll()
        
        while !isAtEnd {
            // Check for using namespace
            if match(.kwUsing) {
                let stmt = try parseUsingNamespace()
                declarations.append(stmt)
                continue
            }
            
            // Check for typedef
            if match(.kwTypedef) {
                try parseTypedef()
                continue
            }
            
            // Check for struct declaration
            if check(.kwStruct) || check(.kwClass) {
                let startLoc = peek().location
                _ = (advance().type == .kwClass)
                if case .identifier(let name) = peek().type {
                    advance()
                    if check(.leftBrace) {
                        let stmt = try parseStructBody(name: name, location: startLoc)
                        declarations.append(stmt)
                        continue
                    } else if match(.semicolon) {
                        // Forward declaration
                        continue
                    } else {
                        // It's a variable declaration with `struct Name var;`
                        let baseType = CType.structType(name)
                        let varDecl = try parseVariableDeclarationTail(baseType: baseType, isConst: false, location: startLoc)
                        declarations.append(varDecl)
                        continue
                    }
                }
            }
            
            // Otherwise, top-level declaration (function or global variable)
            if isTypeBeginning() {
                var isConst = false
                while match(.kwStatic) || match(.kwInline) || match(.kwExtern) || match(.kwConstexpr) || match(.kwVolatile) || match(.kwConst) {
                    if previous().type == .kwConst || previous().type == .kwConstexpr {
                        isConst = true
                    }
                }
                let type = try parseType()
                
                // Check if this is a function definition or global variable
                let decl = try parseTopLevelDeclaration(baseType: type, isConst: isConst)
                declarations.append(decl)
            } else {
                // If it's a semicolon, skip
                if match(.semicolon) { continue }
                throw CCompilerError("Expected top-level declaration (function, variable, or struct)", location: peek().location)
            }
        }
        
        declarations.append(contentsOf: extraTopDeclarations)
        return CProgram(declarations: declarations)
    }
    
    // MARK: - Using Namespace
    
    private func parseUsingNamespace() throws -> CStmt {
        let loc = previous().location
        try consume(.kwNamespace, message: "Expected 'namespace' after 'using'")
        guard case .identifier(let nsName) = advance().type else {
            throw CCompilerError("Expected namespace name", location: loc)
        }
        try consume(.semicolon, message: "Expected ';' after using namespace declaration")
        return .usingNamespace(nsName, loc)
    }
    
    // MARK: - Typedef
    
    private func parseTypedef() throws {
        let loc = previous().location
        if match(.kwStruct) {
            var structName: String? = nil
            if case .identifier(let name) = peek().type {
                advance()
                structName = name
            }
            if check(.leftBrace) {
                _ = try parseStructBody(name: structName ?? "AnonymousStruct", location: loc)
            }
        } else {
            _ = try parseType()
        }
        
        guard case .identifier(let alias) = advance().type else {
            throw CCompilerError("Expected alias name in typedef", location: loc)
        }
        typedefs.insert(alias)
        try consume(.semicolon, message: "Expected ';' after typedef")
    }
    
    // MARK: - Struct / Class
    
    private func parseStructBody(name: String, location: SourceLocation) throws -> CStmt {
        try consume(.leftBrace, message: "Expected '{' to start struct body")
        structNames.insert(name)
        
        var fields: [(type: CType, name: String)] = []
        
        while !check(.rightBrace) && !isAtEnd {
            // Skip public: / private:
            if match(.kwPublic) || match(.kwPrivate) {
                _ = match(.colon)
                continue
            }
            
            // Constructor: StructName(...) { ... }
            if case .identifier(let ctorName) = peek().type, ctorName == name, current + 1 < tokens.count && tokens[current + 1].type == .leftParen {
                let ctorLoc = advance().location
                advance() // consume (
                var params: [(type: CType, name: String, isRef: Bool)] = []
                if !check(.rightParen) {
                    while true {
                        _ = match(.kwConst)
                        let pType = try parseType()
                        var isRef = false
                        if case .reference = pType { isRef = true }
                        var pName = ""
                        if case .identifier(let id) = peek().type {
                            advance()
                            pName = id
                        }
                        params.append((type: pType, name: pName, isRef: isRef))
                        if match(.comma) { continue }
                        break
                    }
                }
                try consume(.rightParen, message: "Expected ')' after constructor params")
                if check(.leftBrace) {
                    let ctorBody = try parseBlock()
                    extraTopDeclarations.append(.funcDecl(returnType: .void, name: "\(name)::\(name)", params: params, body: ctorBody, ctorLoc))
                } else {
                    _ = match(.semicolon)
                }
                continue
            }
            
            // Destructor: ~StructName(...) { ... }
            if match(.tilde) {
                if case .identifier(let dtorName) = peek().type, dtorName == name {
                    let dtorLoc = advance().location
                    try consume(.leftParen, message: "Expected '(' after destructor name")
                    try consume(.rightParen, message: "Expected ')' after destructor params")
                    if check(.leftBrace) {
                        let dtorBody = try parseBlock()
                        extraTopDeclarations.append(.funcDecl(returnType: .void, name: "\(name)::~", params: [], body: dtorBody, dtorLoc))
                    } else {
                        _ = match(.semicolon)
                    }
                    continue
                }
            }
            
            // Static member variable: static int live_instances;
            let isStatic = match(.kwStatic)
            _ = match(.kwConst)
            let fieldType = try parseType()
            
            while true {
                var actualType = fieldType
                while match(.star) {
                    actualType = .pointer(actualType)
                }
                
                guard case .identifier(let fieldName) = advance().type else {
                    throw CCompilerError("Expected field name in struct", location: peek().location)
                }
                
                if isStatic {
                    structNames.insert("\(name)::\(fieldName)")
                    _ = match(.semicolon)
                    break
                }
                
                // Array field
                if match(.leftBracket) {
                    var size: Int? = nil
                    if case .integerLiteral(let s) = peek().type {
                        advance()
                        size = Int(s)
                    }
                    try consume(.rightBracket, message: "Expected ']' in array field declaration")
                    actualType = .array(actualType, size)
                }
                
                fields.append((type: actualType, name: fieldName))
                
                if match(.comma) { continue }
                break
            }
            if !isStatic {
                try consume(.semicolon, message: "Expected ';' after struct member")
            }
        }
        
        try consume(.rightBrace, message: "Expected '}' after struct body")
        
        // Handle typedef struct { ... } Alias;
        if case .identifier(let alias) = peek().type {
            advance()
            typedefs.insert(alias)
            structNames.insert(alias)
        }
        
        try consume(.semicolon, message: "Expected ';' after struct definition")
        return .structDecl(name: name, fields: fields, location: location)
    }
    
    // MARK: - Types
    
    private func isTypeBeginning(at index: Int? = nil) -> Bool {
        let i = index ?? current
        guard i < tokens.count else { return false }
        let t = tokens[i].type
        switch t {
        case .kwInt, .kwFloat, .kwDouble, .kwChar, .kwVoid, .kwBool,
             .kwLong, .kwShort, .kwUnsigned, .kwSigned, .kwConst,
             .kwVolatile, .kwStatic, .kwInline, .kwExtern, .kwConstexpr,
             .kwStruct, .kwClass, .kwAuto:
            return true
        case .identifier(let name):
            if ["string", "vector", "map", "unique_ptr", "shared_ptr", "function"].contains(name) { return true }
            if name == "std" {
                if i + 2 < tokens.count && tokens[i + 1].type == .colonColon {
                    if case .identifier(let sub) = tokens[i + 2].type {
                        if ["string", "vector", "map", "unique_ptr", "shared_ptr", "function"].contains(sub) { return true }
                        if typedefs.contains(sub) || structNames.contains(sub) { return true }
                    }
                }
                return false
            }
            if typedefs.contains(name) || structNames.contains(name) { return true }
            if i + 1 < tokens.count {
                let next = tokens[i + 1].type
                if case .identifier = next { return true }
                if next == .star || next == .ampersand || next == .logicalAnd { return true }
            }
            return false
        default:
            return false
        }
    }
    
    private func parseType() throws -> CType {
        while match(.kwStatic) || match(.kwInline) || match(.kwExtern) || match(.kwConstexpr) || match(.kwVolatile) || match(.kwConst) {}
        
        let isUnsigned = match(.kwUnsigned)
        let isSigned = match(.kwSigned)
        
        var baseType: CType = isUnsigned ? .unsignedInt : .int
        
        if !isAtEnd && !isTypeBeginning() && (isUnsigned || isSigned) {
            baseType = isUnsigned ? .unsignedInt : .int
        } else {
            let token = advance()
            
            switch token.type {
            case .kwInt:
                baseType = isUnsigned ? .unsignedInt : .int
            case .kwFloat:
                baseType = .float
            case .kwDouble:
                baseType = .double
            case .kwChar:
                baseType = isUnsigned ? .unsignedChar : (isSigned ? .signedChar : .char)
            case .kwVoid:
                baseType = .void
            case .kwBool:
                baseType = .bool
            case .kwLong:
                if match(.kwLong) {
                    _ = match(.kwInt)
                    baseType = isUnsigned ? .unsignedLongLong : .longLong
                } else if match(.kwDouble) {
                    baseType = .double
                } else if match(.kwInt) {
                    baseType = isUnsigned ? .unsignedLong : .long
                } else {
                    baseType = isUnsigned ? .unsignedLong : .long
                }
            case .kwShort:
                _ = match(.kwInt)
                baseType = isUnsigned ? .unsignedShort : .short
            case .kwAuto:
                baseType = .custom("auto")
            case .kwStruct, .kwClass:
                guard case .identifier(let name) = advance().type else {
                    throw CCompilerError("Expected struct name", location: token.location)
                }
                baseType = .structType(name)
            case .identifier(let name):
                if name == "std" && match(.colonColon) {
                    guard case .identifier(let stdSub) = advance().type else {
                        throw CCompilerError("Expected type name after std::", location: token.location)
                    }
                    if stdSub == "string" {
                        baseType = .stringType
                    } else if stdSub == "vector" {
                        baseType = try parseVectorType()
                    } else if stdSub == "map" {
                        baseType = try parseMapType()
                    } else if stdSub == "unique_ptr" || stdSub == "shared_ptr" {
                        baseType = try parseSmartPointerType(kind: stdSub)
                    } else if stdSub == "function" {
                        baseType = try parseFunctionType()
                    } else if ["cout", "cin", "endl", "cerr"].contains(stdSub) {
                        throw CCompilerError("'std::\(stdSub)' is not a type", location: token.location)
                    } else {
                        baseType = .custom("std::\(stdSub)")
                        if check(.less) { _ = try parseTemplateBracketTokens() }
                    }
                } else if name == "string" {
                    baseType = .stringType
                } else if name == "vector" {
                    baseType = try parseVectorType()
                } else if name == "map" {
                    baseType = try parseMapType()
                } else if name == "unique_ptr" || name == "shared_ptr" {
                    baseType = try parseSmartPointerType(kind: name)
                } else if name == "function" {
                    baseType = try parseFunctionType()
                } else if structNames.contains(name) {
                    baseType = .structType(name)
                } else {
                    baseType = .custom(name)
                    if check(.less) { _ = try parseTemplateBracketTokens() }
                }
            default:
                throw CCompilerError("Expected type name", location: token.location)
            }
        }
        
        while true {
            if match(.star) {
                baseType = .pointer(baseType)
            } else if match(.logicalAnd) {
                baseType = .rvalueReference(baseType)
            } else if match(.ampersand) {
                baseType = .reference(baseType)
            } else if match(.kwConst) {
                continue
            } else {
                break
            }
        }
        
        return baseType
    }
    
    private func parseVectorType() throws -> CType {
        try consume(.less, message: "Expected '<' after vector")
        let innerType = try parseType()
        try consume(.greater, message: "Expected '>' to close vector type")
        return .vectorType(innerType)
    }
    
    private func parseMapType() throws -> CType {
        try consume(.less, message: "Expected '<' after map")
        let keyType = try parseType()
        try consume(.comma, message: "Expected ',' in map type")
        let valType = try parseType()
        try consume(.greater, message: "Expected '>' to close map type")
        return .mapType(key: keyType, value: valType)
    }
    
    private func parseSmartPointerType(kind: String) throws -> CType {
        try consume(.less, message: "Expected '<' after \(kind)")
        let innerType = try parseType()
        try consume(.greater, message: "Expected '>' to close \(kind) type")
        return .smartPointerType(kind: kind, inner: innerType)
    }
    
    private func parseFunctionType() throws -> CType {
        try consume(.less, message: "Expected '<' after function")
        let retType = try parseType()
        var paramTypes: [CType] = []
        if match(.leftParen) {
            if !check(.rightParen) {
                while true {
                    paramTypes.append(try parseType())
                    if match(.comma) { continue }
                    break
                }
            }
            try consume(.rightParen, message: "Expected ')' in function type")
        }
        try consume(.greater, message: "Expected '>' to close function type")
        return .functionType(returnType: retType, paramTypes: paramTypes)
    }
    
    private func parseTemplateBracketTokens() throws {
        try consume(.less, message: "Expected '<'")
        var depth = 1
        while depth > 0 && !isAtEnd {
            if match(.less) { depth += 1 }
            else if match(.greater) { depth -= 1 }
            else { advance() }
        }
    }
    
    // MARK: - Declarations
    
    private func parseTopLevelDeclaration(baseType: CType, isConst: Bool) throws -> CStmt {
        let loc = peek().location
        
        // Parse pointer stars in declarator
        var finalType = baseType
        while match(.star) {
            finalType = .pointer(finalType)
        }
        
        guard case .identifier(var name) = advance().type else {
            throw CCompilerError("Expected identifier in top-level declaration", location: loc)
        }
        
        if match(.colonColon) {
            guard case .identifier(let member) = advance().type else {
                throw CCompilerError("Expected identifier after '::'", location: loc)
            }
            name = "\(name)::\(member)"
        }
        
        // Check if function
        if match(.leftParen) {
            return try parseFunctionDeclaration(returnType: finalType, name: name, location: loc)
        }
        
        // Check if array
        if match(.leftBracket) {
            var size: Int? = nil
            if case .integerLiteral(let s) = peek().type {
                advance()
                size = Int(s)
            }
            try consume(.rightBracket, message: "Expected ']' in array declaration")
            finalType = .array(finalType, size)
        }
        
        // Global variable
        var initExpr: CExpr? = nil
        if match(.equal) {
            if check(.leftBrace) {
                initExpr = try parseInitializerList()
            } else {
                initExpr = try parseExpression()
            }
        }
        
        try consume(.semicolon, message: "Expected ';' after variable declaration")
        return .variableDecl(type: finalType, name: name, initExpr: initExpr, isConst: isConst, loc)
    }
    
    private func parseFunctionDeclaration(returnType: CType, name: String, location: SourceLocation) throws -> CStmt {
        var params: [(type: CType, name: String, isRef: Bool)] = []
        
        if !check(.rightParen) {
            while true {
                if match(.kwVoid) && check(.rightParen) {
                    break
                }
                
                _ = match(.kwConst)
                var pType = try parseType()
                var isRef = false
                if case .reference = pType {
                    isRef = true
                }
                
                var pName = ""
                if case .identifier(let id) = peek().type {
                    advance()
                    pName = id
                }
                
                // Array parameter decays to pointer
                if match(.leftBracket) {
                    _ = match(.integerLiteral(0))
                    try consume(.rightBracket, message: "Expected ']' in array parameter")
                    pType = .pointer(pType)
                }
                
                params.append((type: pType, name: pName, isRef: isRef))
                
                if match(.comma) { continue }
                break
            }
        }
        
        try consume(.rightParen, message: "Expected ')' after parameter list")
        
        if match(.semicolon) {
            // Function prototype without body
            return .funcDecl(returnType: returnType, name: name, params: params, body: nil, location)
        }
        
        // Function body
        let body = try parseBlock()
        return .funcDecl(returnType: returnType, name: name, params: params, body: body, location)
    }
    
    // MARK: - Statements
    
    private func parseStatement() throws -> CStmt {
        if check(.leftBrace) {
            return try parseBlock()
        }
        
        if match(.kwIf) {
            return try parseIfStatement()
        }
        
        if match(.kwWhile) {
            return try parseWhileStatement()
        }
        
        if match(.kwDo) {
            return try parseDoWhileStatement()
        }
        
        if match(.kwFor) {
            return try parseForStatement()
        }
        
        if match(.kwSwitch) {
            return try parseSwitchStatement()
        }
        
        if match(.kwReturn) {
            let loc = previous().location
            var expr: CExpr? = nil
            if !check(.semicolon) {
                expr = try parseExpression()
            }
            try consume(.semicolon, message: "Expected ';' after return")
            return .returnStmt(expr, loc)
        }
        
        if match(.kwBreak) {
            let loc = previous().location
            try consume(.semicolon, message: "Expected ';' after break")
            return .breakStmt(loc)
        }
        
        if match(.kwContinue) {
            let loc = previous().location
            try consume(.semicolon, message: "Expected ';' after continue")
            return .continueStmt(loc)
        }
        
        // Variable declaration
        if isTypeBeginning() {
            var isConst = false
            while match(.kwStatic) || match(.kwInline) || match(.kwExtern) || match(.kwConstexpr) || match(.kwVolatile) || match(.kwConst) {
                if previous().type == .kwConst || previous().type == .kwConstexpr {
                    isConst = true
                }
            }
            let type = try parseType()
            return try parseVariableDeclarationTail(baseType: type, isConst: isConst, location: previous().location)
        }
        
        // Expression statement
        let expr = try parseExpression()
        try consume(.semicolon, message: "Expected ';' after expression")
        return .expr(expr, expr.location)
    }
    
    private func parseBlock() throws -> CStmt {
        let loc = peek().location
        try consume(.leftBrace, message: "Expected '{' to start block")
        var statements: [CStmt] = []
        
        while !check(.rightBrace) && !isAtEnd {
            statements.append(try parseStatement())
        }
        
        try consume(.rightBrace, message: "Expected '}' to close block")
        return .block(statements, loc)
    }
    
    private func parseVariableDeclarationTail(baseType: CType, isConst: Bool, location: SourceLocation) throws -> CStmt {
        var statements: [CStmt] = []
        
        while true {
            var varType = baseType
            while match(.star) {
                varType = .pointer(varType)
            }
            while match(.ampersand) {
                varType = .reference(varType)
            }
            
            guard case .identifier(let name) = advance().type else {
                throw CCompilerError("Expected variable name", location: location)
            }
            
            // Check array
            var arraySize: Int? = nil
            if match(.leftBracket) {
                if case .integerLiteral(let s) = peek().type {
                    advance()
                    arraySize = Int(s)
                }
                try consume(.rightBracket, message: "Expected ']' in array declaration")
                varType = .array(varType, arraySize)
            }
            
            var initExpr: CExpr? = nil
            if match(.equal) {
                if check(.leftBrace) {
                    let initList = try parseInitializerList()
                    initExpr = initList
                    if case .initializerList(let items, _) = initList, arraySize == nil {
                        varType = .array(baseType, items.count)
                    }
                } else {
                    initExpr = try parseExpression()
                }
            } else if match(.leftParen) {
                // Constructor call style: int a(5); or string s("abc");
                let arg = try parseExpression()
                try consume(.rightParen, message: "Expected ')' after constructor argument")
                initExpr = arg
            }
            
            statements.append(.variableDecl(type: varType, name: name, initExpr: initExpr, isConst: isConst, location))
            
            if match(.comma) { continue }
            break
        }
        
        try consume(.semicolon, message: "Expected ';' after variable declaration")
        if statements.count == 1 {
            return statements[0]
        }
        return .block(statements, location)
    }
    
    private func parseInitializerList() throws -> CExpr {
        let loc = peek().location
        try consume(.leftBrace, message: "Expected '{' in initializer list")
        var items: [CExpr] = []
        
        if !check(.rightBrace) {
            while true {
                if check(.leftBrace) {
                    items.append(try parseInitializerList())
                } else {
                    items.append(try parseExpression())
                }
                if match(.comma) {
                    if check(.rightBrace) { break }
                    continue
                }
                break
            }
        }
        
        try consume(.rightBrace, message: "Expected '}' in initializer list")
        return .initializerList(items, loc)
    }
    
    private func parseIfStatement() throws -> CStmt {
        let loc = previous().location
        try consume(.leftParen, message: "Expected '(' after 'if'")
        let condition = try parseExpression()
        try consume(.rightParen, message: "Expected ')' after if condition")
        
        let thenStmt = try parseStatement()
        var elseStmt: CStmt? = nil
        if match(.kwElse) {
            elseStmt = try parseStatement()
        }
        
        return .ifStmt(condition: condition, thenStmt: thenStmt, elseStmt: elseStmt, loc)
    }
    
    private func parseWhileStatement() throws -> CStmt {
        let loc = previous().location
        try consume(.leftParen, message: "Expected '(' after 'while'")
        let condition = try parseExpression()
        try consume(.rightParen, message: "Expected ')' after while condition")
        let body = try parseStatement()
        return .whileStmt(condition: condition, body: body, loc)
    }
    
    private func parseDoWhileStatement() throws -> CStmt {
        let loc = previous().location
        let body = try parseStatement()
        try consume(.kwWhile, message: "Expected 'while' after do block")
        try consume(.leftParen, message: "Expected '(' after 'while'")
        let condition = try parseExpression()
        try consume(.rightParen, message: "Expected ')' after do-while condition")
        try consume(.semicolon, message: "Expected ';' after do-while statement")
        return .doWhileStmt(body: body, condition: condition, loc)
    }
    
    private func parseForStatement() throws -> CStmt {
        let loc = previous().location
        try consume(.leftParen, message: "Expected '(' after 'for'")
        
        var initStmt: CStmt? = nil
        if !match(.semicolon) {
            if isTypeBeginning() {
                var isConst = false
                while match(.kwStatic) || match(.kwInline) || match(.kwExtern) || match(.kwConstexpr) || match(.kwVolatile) || match(.kwConst) {
                    if previous().type == .kwConst || previous().type == .kwConstexpr {
                        isConst = true
                    }
                }
                let type = try parseType()
                initStmt = try parseVariableDeclarationTail(baseType: type, isConst: isConst, location: peek().location)
            } else {
                let expr = try parseExpression()
                try consume(.semicolon, message: "Expected ';' after for init expression")
                initStmt = .expr(expr, expr.location)
            }
        }
        
        var condition: CExpr? = nil
        if !match(.semicolon) {
            condition = try parseExpression()
            try consume(.semicolon, message: "Expected ';' after for condition")
        }
        
        var stepExpr: CExpr? = nil
        if !check(.rightParen) {
            stepExpr = try parseExpression()
        }
        
        try consume(.rightParen, message: "Expected ')' after for clauses")
        let body = try parseStatement()
        
        return .forStmt(initStmt: initStmt, condition: condition, stepExpr: stepExpr, body: body, loc)
    }
    
    private func parseSwitchStatement() throws -> CStmt {
        let loc = previous().location
        try consume(.leftParen, message: "Expected '(' after 'switch'")
        let condition = try parseExpression()
        try consume(.rightParen, message: "Expected ')' after switch condition")
        try consume(.leftBrace, message: "Expected '{' to start switch body")
        
        var cases: [(CExpr?, [CStmt])] = []
        
        while !check(.rightBrace) && !isAtEnd {
            if match(.kwCase) {
                let caseVal = try parseExpression()
                try consume(.colon, message: "Expected ':' after case value")
                var caseStmts: [CStmt] = []
                while !check(.kwCase) && !check(.kwDefault) && !check(.rightBrace) && !isAtEnd {
                    caseStmts.append(try parseStatement())
                }
                cases.append((caseVal, caseStmts))
            } else if match(.kwDefault) {
                try consume(.colon, message: "Expected ':' after default")
                var defaultStmts: [CStmt] = []
                while !check(.kwCase) && !check(.kwDefault) && !check(.rightBrace) && !isAtEnd {
                    defaultStmts.append(try parseStatement())
                }
                cases.append((nil, defaultStmts))
            } else {
                throw CCompilerError("Expected 'case' or 'default' inside switch", location: peek().location)
            }
        }
        
        try consume(.rightBrace, message: "Expected '}' to close switch body")
        return .switchStmt(condition: condition, cases: cases, loc)
    }
    
    // MARK: - Expressions
    
    public func parseExpression() throws -> CExpr {
        return try parseAssignment()
    }
    
    private func parseAssignment() throws -> CExpr {
        let expr = try parseTernary()
        
        if match(.equal) {
            let val = try parseAssignment()
            return .assignment(.assign, expr, val, expr.location)
        } else if match(.plusEqual) {
            let val = try parseAssignment()
            return .assignment(.addAssign, expr, val, expr.location)
        } else if match(.minusEqual) {
            let val = try parseAssignment()
            return .assignment(.subAssign, expr, val, expr.location)
        } else if match(.starEqual) {
            let val = try parseAssignment()
            return .assignment(.mulAssign, expr, val, expr.location)
        } else if match(.slashEqual) {
            let val = try parseAssignment()
            return .assignment(.divAssign, expr, val, expr.location)
        } else if match(.percentEqual) {
            let val = try parseAssignment()
            return .assignment(.modAssign, expr, val, expr.location)
        } else if match(.ampersandEqual) {
            let val = try parseAssignment()
            return .assignment(.andAssign, expr, val, expr.location)
        } else if match(.pipeEqual) {
            let val = try parseAssignment()
            return .assignment(.orAssign, expr, val, expr.location)
        } else if match(.caretEqual) {
            let val = try parseAssignment()
            return .assignment(.xorAssign, expr, val, expr.location)
        } else if match(.leftShiftEqual) {
            let val = try parseAssignment()
            return .assignment(.shlAssign, expr, val, expr.location)
        } else if match(.rightShiftEqual) {
            let val = try parseAssignment()
            return .assignment(.shrAssign, expr, val, expr.location)
        }
        
        return expr
    }
    
    private func parseTernary() throws -> CExpr {
        let expr = try parseLogicalOr()
        
        if match(.question) {
            let loc = previous().location
            let thenExpr = try parseExpression()
            try consume(.colon, message: "Expected ':' in ternary operator")
            let elseExpr = try parseTernary()
            return .ternary(expr, thenExpr, elseExpr, loc)
        }
        
        return expr
    }
    
    private func parseLogicalOr() throws -> CExpr {
        var expr = try parseLogicalAnd()
        while match(.logicalOr) {
            let loc = previous().location
            let right = try parseLogicalAnd()
            expr = .binary(.logicalOr, expr, right, loc)
        }
        return expr
    }
    
    private func parseLogicalAnd() throws -> CExpr {
        var expr = try parseBitwiseOr()
        while match(.logicalAnd) {
            let loc = previous().location
            let right = try parseBitwiseOr()
            expr = .binary(.logicalAnd, expr, right, loc)
        }
        return expr
    }
    
    private func parseBitwiseOr() throws -> CExpr {
        var expr = try parseBitwiseXor()
        while match(.pipe) {
            let loc = previous().location
            let right = try parseBitwiseXor()
            expr = .binary(.bitwiseOr, expr, right, loc)
        }
        return expr
    }
    
    private func parseBitwiseXor() throws -> CExpr {
        var expr = try parseBitwiseAnd()
        while match(.caret) {
            let loc = previous().location
            let right = try parseBitwiseAnd()
            expr = .binary(.bitwiseXor, expr, right, loc)
        }
        return expr
    }
    
    private func parseBitwiseAnd() throws -> CExpr {
        var expr = try parseEquality()
        while match(.ampersand) {
            let loc = previous().location
            let right = try parseEquality()
            expr = .binary(.bitwiseAnd, expr, right, loc)
        }
        return expr
    }
    
    private func parseEquality() throws -> CExpr {
        var expr = try parseRelational()
        while true {
            if match(.equalEqual) {
                let loc = previous().location
                let right = try parseRelational()
                expr = .binary(.equal, expr, right, loc)
            } else if match(.notEqual) {
                let loc = previous().location
                let right = try parseRelational()
                expr = .binary(.notEqual, expr, right, loc)
            } else {
                break
            }
        }
        return expr
    }
    
    private func parseRelational() throws -> CExpr {
        var expr = try parseShift()
        while true {
            if match(.less) {
                let loc = previous().location
                let right = try parseShift()
                expr = .binary(.less, expr, right, loc)
            } else if match(.lessEqual) {
                let loc = previous().location
                let right = try parseShift()
                expr = .binary(.lessEqual, expr, right, loc)
            } else if match(.greater) {
                let loc = previous().location
                let right = try parseShift()
                expr = .binary(.greater, expr, right, loc)
            } else if match(.greaterEqual) {
                let loc = previous().location
                let right = try parseShift()
                expr = .binary(.greaterEqual, expr, right, loc)
            } else {
                break
            }
        }
        return expr
    }
    
    private func parseShift() throws -> CExpr {
        var expr = try parseAdditive()
        while true {
            if match(.leftShift) {
                let loc = previous().location
                let right = try parseAdditive()
                expr = .binary(.leftShift, expr, right, loc)
            } else if match(.rightShift) {
                let loc = previous().location
                let right = try parseAdditive()
                expr = .binary(.rightShift, expr, right, loc)
            } else {
                break
            }
        }
        return expr
    }
    
    private func parseAdditive() throws -> CExpr {
        var expr = try parseMultiplicative()
        while true {
            if match(.plus) {
                let loc = previous().location
                let right = try parseMultiplicative()
                expr = .binary(.add, expr, right, loc)
            } else if match(.minus) {
                let loc = previous().location
                let right = try parseMultiplicative()
                expr = .binary(.subtract, expr, right, loc)
            } else {
                break
            }
        }
        return expr
    }
    
    private func parseMultiplicative() throws -> CExpr {
        var expr = try parseUnary()
        while true {
            if match(.star) {
                let loc = previous().location
                let right = try parseUnary()
                expr = .binary(.multiply, expr, right, loc)
            } else if match(.slash) {
                let loc = previous().location
                let right = try parseUnary()
                expr = .binary(.divide, expr, right, loc)
            } else if match(.percent) {
                let loc = previous().location
                let right = try parseUnary()
                expr = .binary(.modulo, expr, right, loc)
            } else {
                break
            }
        }
        return expr
    }
    
    private func parseUnary() throws -> CExpr {
        let loc = peek().location
        
        if match(.plusPlus) {
            let operand = try parseUnary()
            return .unary(.preInc, operand, loc)
        }
        if match(.minusMinus) {
            let operand = try parseUnary()
            return .unary(.preDec, operand, loc)
        }
        if match(.plus) {
            let operand = try parseUnary()
            return .unary(.plus, operand, loc)
        }
        if match(.minus) {
            let operand = try parseUnary()
            return .unary(.negate, operand, loc)
        }
        if match(.logicalNot) {
            let operand = try parseUnary()
            return .unary(.logicalNot, operand, loc)
        }
        if match(.tilde) {
            let operand = try parseUnary()
            return .unary(.bitwiseNot, operand, loc)
        }
        if match(.star) {
            let operand = try parseUnary()
            return .unary(.dereference, operand, loc)
        }
        if match(.ampersand) {
            let operand = try parseUnary()
            return .unary(.addressOf, operand, loc)
        }
        if match(.kwSizeof) {
            if match(.leftParen) {
                if isTypeBeginning() {
                    let type = try parseType()
                    try consume(.rightParen, message: "Expected ')' after sizeof type")
                    return .sizeofType(type, loc)
                } else {
                    let expr = try parseExpression()
                    try consume(.rightParen, message: "Expected ')' after sizeof expression")
                    return .sizeofExpr(expr, loc)
                }
            } else {
                let operand = try parseUnary()
                return .sizeofExpr(operand, loc)
            }
        }
        
        // Type cast: (type)expr
        if check(.leftParen) {
            let nextIndex = current + 1
            if nextIndex < tokens.count {
                let isType = isTypeBeginning(at: nextIndex)
                if isType {
                    advance() // (
                    let castType = try parseType()
                    try consume(.rightParen, message: "Expected ')' in type cast")
                    let operand = try parseUnary()
                    return .cast(castType, operand, loc)
                }
            }
        }
        
        return try parsePostfix()
    }
    
    private func parsePostfix() throws -> CExpr {
        var expr = try parsePrimary()
        
        while true {
            let loc = peek().location
            if match(.plusPlus) {
                expr = .unary(.postInc, expr, loc)
            } else if match(.minusMinus) {
                expr = .unary(.postDec, expr, loc)
            } else if match(.leftParen) {
                // Function call
                var args: [CExpr] = []
                if !check(.rightParen) {
                    while true {
                        args.append(try parseExpression())
                        if match(.comma) { continue }
                        break
                    }
                }
                try consume(.rightParen, message: "Expected ')' after argument list")
                expr = .call(expr, args, loc)
            } else if match(.leftBracket) {
                // Subscript
                let index = try parseExpression()
                try consume(.rightBracket, message: "Expected ']' after array index")
                expr = .subscriptAccess(expr, index, loc)
            } else if match(.dot) {
                guard case .identifier(let member) = advance().type else {
                    throw CCompilerError("Expected member name after '.'", location: loc)
                }
                expr = .memberAccess(expr, member, isArrow: false, loc)
            } else if match(.arrow) {
                guard case .identifier(let member) = advance().type else {
                    throw CCompilerError("Expected member name after '->'", location: loc)
                }
                expr = .memberAccess(expr, member, isArrow: true, loc)
            } else {
                break
            }
        }
        
        return expr
    }
    
    private func parsePrimary() throws -> CExpr {
        let loc = peek().location
        
        if case .integerLiteral(let val) = peek().type {
            advance()
            return .literalInt(val, loc)
        }
        if case .floatLiteral(let val) = peek().type {
            advance()
            return .literalDouble(val, loc)
        }
        if case .charLiteral(let val) = peek().type {
            advance()
            return .literalChar(val, loc)
        }
        if case .stringLiteral(let val) = peek().type {
            advance()
            return .literalString(val, loc)
        }
        if match(.kwTrue) {
            return .literalBool(true, loc)
        }
        if match(.kwFalse) {
            return .literalBool(false, loc)
        }
        if match(.kwNull) || match(.kwNullptr) {
            return .literalNull(loc)
        }
        
        // C++ new expression: new Type(...)
        if match(.kwNew) {
            let type = try parseType()
            var args: [CExpr] = []
            if match(.leftParen) {
                if !check(.rightParen) {
                    while true {
                        args.append(try parseExpression())
                        if match(.comma) { continue }
                        break
                    }
                }
                try consume(.rightParen, message: "Expected ')' after new arguments")
            }
            return .newExpr(type: type, args: args, loc)
        }
        
        // Lambda expression: [captures](params) { body }
        if check(.leftBracket) {
            advance() // [
            var captures: [String] = []
            while !check(.rightBracket) && !isAtEnd {
                if match(.ampersand) {
                    if case .identifier(let cap) = peek().type {
                        advance()
                        captures.append("&\(cap)")
                    } else {
                        captures.append("&")
                    }
                } else if match(.equal) {
                    captures.append("=")
                } else if case .identifier(let cap) = advance().type {
                    captures.append(cap)
                }
                if match(.comma) { continue }
                break
            }
            try consume(.rightBracket, message: "Expected ']' after lambda capture list")
            
            var params: [(type: CType, name: String, isRef: Bool)] = []
            if match(.leftParen) {
                if !check(.rightParen) {
                    while true {
                        _ = match(.kwConst)
                        let pType = try parseType()
                        var isRef = false
                        if case .reference = pType { isRef = true }
                        var pName = ""
                        if case .identifier(let id) = peek().type {
                            advance()
                            pName = id
                        }
                        params.append((type: pType, name: pName, isRef: isRef))
                        if match(.comma) { continue }
                        break
                    }
                }
                try consume(.rightParen, message: "Expected ')' after lambda parameters")
            }
            
            let body = try parseBlock()
            return .lambda(captures: captures, params: params, body: body, loc)
        }
        
        // Scope resolution identifier: std::cout, std::cin, Tracker::live_instances, or general id
        if case .identifier(let name) = peek().type {
            advance()
            var ns: String? = nil
            var varName = name
            if match(.colonColon) {
                guard case .identifier(let member) = advance().type else {
                    throw CCompilerError("Expected identifier after '::'", location: loc)
                }
                if name == "std" {
                    ns = "std"
                    varName = member
                } else {
                    varName = "\(name)::\(member)"
                }
            }
            
            // Check if followed by template spec in expression: name<Type>(...)
            if check(.less) {
                var k = current + 1
                var depth = 1
                while k < tokens.count && depth > 0 {
                    if tokens[k].type == .less { depth += 1 }
                    else if tokens[k].type == .greater { depth -= 1 }
                    k += 1
                }
                if depth == 0 && k < tokens.count && tokens[k].type == .leftParen {
                    advance() // consume <
                    depth = 1
                    while depth > 0 && !isAtEnd {
                        if match(.less) { depth += 1 }
                        else if match(.greater) { depth -= 1 }
                        else { advance() }
                    }
                }
            }
            
            return .identifier(varName, namespace: ns, loc)
        }
        
        // Parenthesized expression
        if match(.leftParen) {
            let expr = try parseExpression()
            try consume(.rightParen, message: "Expected ')' after expression")
            return expr
        }
        
        throw CCompilerError("Expected expression, found '\(peek().raw)'", location: loc)
    }
}
