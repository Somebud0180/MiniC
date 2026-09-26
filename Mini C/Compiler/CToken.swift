import Foundation

// MARK: - Token Types

public enum CTokenType: Equatable, Sendable {
    // Keywords
    case kwInt, kwFloat, kwDouble, kwChar, kwVoid, kwBool
    case kwLong, kwShort, kwUnsigned, kwSigned
    case kwConst, kwStatic, kwAuto, kwInline, kwExtern, kwVolatile, kwConstexpr
    case kwStruct, kwClass, kwPublic, kwPrivate, kwTypedef
    case kwIf, kwElse, kwWhile, kwFor, kwDo, kwReturn, kwBreak, kwContinue
    case kwSwitch, kwCase, kwDefault, kwSizeof, kwNew, kwDelete
    case kwUsing, kwNamespace, kwTrue, kwFalse, kwNull, kwNullptr
    
    // Identifiers & Literals
    case identifier(String)
    case integerLiteral(Int64)
    case floatLiteral(Double)
    case charLiteral(UInt8)
    case stringLiteral(String)
    case boolLiteral(Bool)
    
    // Operators
    case plus           // +
    case minus          // -
    case star           // *
    case slash          // /
    case percent        // %
    case plusPlus       // ++
    case minusMinus     // --
    
    case equal          // =
    case plusEqual      // +=
    case minusEqual     // -=
    case starEqual      // *=
    case slashEqual     // /=
    case percentEqual   // %=
    case ampersandEqual // &=
    case pipeEqual      // |=
    case caretEqual     // ^=
    case leftShiftEqual // <<=
    case rightShiftEqual// >>=
    
    case equalEqual     // ==
    case notEqual       // !=
    case less           // <
    case lessEqual      // <=
    case greater        // >
    case greaterEqual   // >=
    
    case logicalAnd     // &&
    case logicalOr      // ||
    case logicalNot     // !
    
    case ampersand      // &
    case pipe           // |
    case caret          // ^
    case tilde          // ~
    case leftShift      // <<
    case rightShift     // >>
    
    case question       // ?
    case colon          // :
    case colonColon     // ::
    case dot            // .
    case arrow          // ->
    
    // Delimiters
    case leftParen      // (
    case rightParen     // )
    case leftBrace      // {
    case rightBrace     // }
    case leftBracket    // [
    case rightBracket   // ]
    case semicolon      // ;
    case comma          // ,
    case hash           // #
    
    case eof
}

public struct SourceLocation: Equatable, Sendable {
    public let line: Int
    public let column: Int
    
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct CToken: Equatable, Sendable {
    public let type: CTokenType
    public let location: SourceLocation
    public let raw: String
    
    public init(type: CTokenType, location: SourceLocation, raw: String) {
        self.type = type
        self.location = location
        self.raw = raw
    }
}

// MARK: - Lexer

public final class CLexer {
    private let source: String
    private var index: String.Index
    private var line: Int = 1
    private var column: Int = 1
    
    public init(source: String) {
        self.source = source
        self.index = source.startIndex
    }
    
    private var isAtEnd: Bool {
        index >= source.endIndex
    }
    
    private var currentChar: Character? {
        isAtEnd ? nil : source[index]
    }
    
    private func peek(offset: Int = 1) -> Character? {
        var peekIdx = index
        for _ in 0..<offset {
            if peekIdx >= source.endIndex { return nil }
            peekIdx = source.index(after: peekIdx)
        }
        return peekIdx < source.endIndex ? source[peekIdx] : nil
    }
    
    @discardableResult
    private func advance() -> Character {
        let ch = source[index]
        index = source.index(after: index)
        if ch == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return ch
    }
    
    public func tokenize() throws -> [CToken] {
        var tokens: [CToken] = []
        
        while !isAtEnd {
            skipWhitespaceAndComments()
            if isAtEnd { break }
            
            let startLoc = SourceLocation(line: line, column: column)
            let ch = advance()
            
            switch ch {
            case "(": tokens.append(CToken(type: .leftParen, location: startLoc, raw: "("))
            case ")": tokens.append(CToken(type: .rightParen, location: startLoc, raw: ")"))
            case "{": tokens.append(CToken(type: .leftBrace, location: startLoc, raw: "{"))
            case "}": tokens.append(CToken(type: .rightBrace, location: startLoc, raw: "}"))
            case "[": tokens.append(CToken(type: .leftBracket, location: startLoc, raw: "["))
            case "]": tokens.append(CToken(type: .rightBracket, location: startLoc, raw: "]"))
            case ";": tokens.append(CToken(type: .semicolon, location: startLoc, raw: ";"))
            case ",": tokens.append(CToken(type: .comma, location: startLoc, raw: ","))
            case "?": tokens.append(CToken(type: .question, location: startLoc, raw: "?"))
            case "~": tokens.append(CToken(type: .tilde, location: startLoc, raw: "~"))
            case "#": tokens.append(CToken(type: .hash, location: startLoc, raw: "#"))
                
            case ":":
                if match(":") {
                    tokens.append(CToken(type: .colonColon, location: startLoc, raw: "::"))
                } else {
                    tokens.append(CToken(type: .colon, location: startLoc, raw: ":"))
                }
                
            case "+":
                if match("+") {
                    tokens.append(CToken(type: .plusPlus, location: startLoc, raw: "++"))
                } else if match("=") {
                    tokens.append(CToken(type: .plusEqual, location: startLoc, raw: "+="))
                } else {
                    tokens.append(CToken(type: .plus, location: startLoc, raw: "+"))
                }
                
            case "-":
                if match("-") {
                    tokens.append(CToken(type: .minusMinus, location: startLoc, raw: "--"))
                } else if match("=") {
                    tokens.append(CToken(type: .minusEqual, location: startLoc, raw: "-="))
                } else if match(">") {
                    tokens.append(CToken(type: .arrow, location: startLoc, raw: "->"))
                } else {
                    tokens.append(CToken(type: .minus, location: startLoc, raw: "-"))
                }
                
            case "*":
                if match("=") {
                    tokens.append(CToken(type: .starEqual, location: startLoc, raw: "*="))
                } else {
                    tokens.append(CToken(type: .star, location: startLoc, raw: "*"))
                }
                
            case "/":
                if match("=") {
                    tokens.append(CToken(type: .slashEqual, location: startLoc, raw: "/="))
                } else {
                    tokens.append(CToken(type: .slash, location: startLoc, raw: "/"))
                }
                
            case "%":
                if match("=") {
                    tokens.append(CToken(type: .percentEqual, location: startLoc, raw: "%="))
                } else {
                    tokens.append(CToken(type: .percent, location: startLoc, raw: "%"))
                }
                
            case "=":
                if match("=") {
                    tokens.append(CToken(type: .equalEqual, location: startLoc, raw: "=="))
                } else {
                    tokens.append(CToken(type: .equal, location: startLoc, raw: "="))
                }
                
            case "!":
                if match("=") {
                    tokens.append(CToken(type: .notEqual, location: startLoc, raw: "!="))
                } else {
                    tokens.append(CToken(type: .logicalNot, location: startLoc, raw: "!"))
                }
                
            case "<":
                if match("<") {
                    if match("=") {
                        tokens.append(CToken(type: .leftShiftEqual, location: startLoc, raw: "<<="))
                    } else {
                        tokens.append(CToken(type: .leftShift, location: startLoc, raw: "<<"))
                    }
                } else if match("=") {
                    tokens.append(CToken(type: .lessEqual, location: startLoc, raw: "<="))
                } else {
                    tokens.append(CToken(type: .less, location: startLoc, raw: "<"))
                }
                
            case ">":
                if match(">") {
                    if match("=") {
                        tokens.append(CToken(type: .rightShiftEqual, location: startLoc, raw: ">>="))
                    } else {
                        tokens.append(CToken(type: .rightShift, location: startLoc, raw: ">>"))
                    }
                } else if match("=") {
                    tokens.append(CToken(type: .greaterEqual, location: startLoc, raw: ">="))
                } else {
                    tokens.append(CToken(type: .greater, location: startLoc, raw: ">"))
                }
                
            case "&":
                if match("&") {
                    tokens.append(CToken(type: .logicalAnd, location: startLoc, raw: "&&"))
                } else if match("=") {
                    tokens.append(CToken(type: .ampersandEqual, location: startLoc, raw: "&="))
                } else {
                    tokens.append(CToken(type: .ampersand, location: startLoc, raw: "&"))
                }
                
            case "|":
                if match("|") {
                    tokens.append(CToken(type: .logicalOr, location: startLoc, raw: "||"))
                } else if match("=") {
                    tokens.append(CToken(type: .pipeEqual, location: startLoc, raw: "|="))
                } else {
                    tokens.append(CToken(type: .pipe, location: startLoc, raw: "|"))
                }
                
            case "^":
                if match("=") {
                    tokens.append(CToken(type: .caretEqual, location: startLoc, raw: "^="))
                } else {
                    tokens.append(CToken(type: .caret, location: startLoc, raw: "^"))
                }
                
            case ".":
                tokens.append(CToken(type: .dot, location: startLoc, raw: "."))
                
            case "\"":
                let str = try scanStringLiteral()
                tokens.append(CToken(type: .stringLiteral(str), location: startLoc, raw: "\"\(str)\""))
                
            case "'":
                let byte = try scanCharLiteral()
                tokens.append(CToken(type: .charLiteral(byte), location: startLoc, raw: "'\(Character(UnicodeScalar(byte)))'"))
                
            default:
                if ch.isNumber {
                    tokens.append(try scanNumber(startChar: ch, startLoc: startLoc))
                } else if ch.isLetter || ch == "_" {
                    tokens.append(scanIdentifierOrKeyword(startChar: ch, startLoc: startLoc))
                }
            }
        }
        
        tokens.append(CToken(type: .eof, location: SourceLocation(line: line, column: column), raw: ""))
        return tokens
    }
    
    private func match(_ expected: Character) -> Bool {
        guard let ch = currentChar, ch == expected else { return false }
        advance()
        return true
    }
    
    private func skipWhitespaceAndComments() {
        while !isAtEnd {
            guard let ch = currentChar else { break }
            if ch.isWhitespace {
                advance()
            } else if ch == "/" && peek() == "/" {
                advance() // /
                advance() // /
                while !isAtEnd && currentChar != "\n" {
                    advance()
                }
            } else if ch == "/" && peek() == "*" {
                advance() // /
                advance() // *
                while !isAtEnd {
                    if currentChar == "*" && peek() == "/" {
                        advance() // *
                        advance() // /
                        break
                    }
                    advance()
                }
            } else {
                break
            }
        }
    }
    
    private func scanStringLiteral() throws -> String {
        var result = ""
        while !isAtEnd && currentChar != "\"" {
            if currentChar == "\\" {
                advance()
                guard !isAtEnd else { break }
                let esc = advance()
                switch esc {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "'": result.append("'")
                default: result.append(esc)
                }
            } else {
                result.append(advance())
            }
        }
        if !isAtEnd && currentChar == "\"" {
            advance()
        }
        return result
    }
    
    private func scanCharLiteral() throws -> UInt8 {
        var byte: UInt8 = 0
        if !isAtEnd && currentChar != "'" {
            if currentChar == "\\" {
                advance()
                guard !isAtEnd else { return 0 }
                let esc = advance()
                switch esc {
                case "n": byte = 10
                case "t": byte = 9
                case "r": byte = 13
                case "0": byte = 0
                case "\\": byte = 92
                case "'": byte = 39
                case "\"": byte = 34
                default: byte = esc.asciiValue ?? 0
                }
            } else {
                let ch = advance()
                byte = ch.asciiValue ?? 0
            }
        }
        if !isAtEnd && currentChar == "'" {
            advance()
        }
        return byte
    }
    
    private func scanNumber(startChar: Character, startLoc: SourceLocation) throws -> CToken {
        var raw = String(startChar)
        var isFloat = false
        
        if startChar == "0" && (currentChar == "x" || currentChar == "X") {
            raw.append(advance())
            while let c = currentChar, c.isHexDigit {
                raw.append(advance())
            }
            let clean = raw.dropFirst(2)
            let val = Int64(clean, radix: 16) ?? 0
            return CToken(type: .integerLiteral(val), location: startLoc, raw: raw)
        }
        
        while let ch = currentChar {
            if ch.isNumber {
                raw.append(advance())
            } else if ch == "." && !isFloat && (peek()?.isNumber == true) {
                isFloat = true
                raw.append(advance())
            } else if ch == "e" || ch == "E" {
                isFloat = true
                raw.append(advance())
                if currentChar == "+" || currentChar == "-" {
                    raw.append(advance())
                }
            } else if ch == "f" || ch == "F" || ch == "u" || ch == "U" || ch == "l" || ch == "L" {
                advance()
            } else {
                break
            }
        }
        
        if isFloat {
            let val = Double(raw) ?? 0.0
            return CToken(type: .floatLiteral(val), location: startLoc, raw: raw)
        } else {
            let val = Int64(raw) ?? 0
            return CToken(type: .integerLiteral(val), location: startLoc, raw: raw)
        }
    }
    
    private func scanIdentifierOrKeyword(startChar: Character, startLoc: SourceLocation) -> CToken {
        var word = String(startChar)
        while let ch = currentChar, ch.isLetter || ch.isNumber || ch == "_" {
            word.append(advance())
        }
        
        let type: CTokenType
        switch word {
        case "int": type = .kwInt
        case "float": type = .kwFloat
        case "double": type = .kwDouble
        case "char": type = .kwChar
        case "void": type = .kwVoid
        case "bool": type = .kwBool
        case "long": type = .kwLong
        case "short": type = .kwShort
        case "unsigned": type = .kwUnsigned
        case "signed": type = .kwSigned
        case "const": type = .kwConst
        case "inline": type = .kwInline
        case "extern": type = .kwExtern
        case "volatile": type = .kwVolatile
        case "constexpr": type = .kwConstexpr
        case "static": type = .kwStatic
        case "auto": type = .kwAuto
        case "struct": type = .kwStruct
        case "class": type = .kwClass
        case "public": type = .kwPublic
        case "private": type = .kwPrivate
        case "typedef": type = .kwTypedef
        case "if": type = .kwIf
        case "else": type = .kwElse
        case "while": type = .kwWhile
        case "for": type = .kwFor
        case "do": type = .kwDo
        case "return": type = .kwReturn
        case "break": type = .kwBreak
        case "continue": type = .kwContinue
        case "switch": type = .kwSwitch
        case "case": type = .kwCase
        case "default": type = .kwDefault
        case "sizeof": type = .kwSizeof
        case "new": type = .kwNew
        case "delete": type = .kwDelete
        case "using": type = .kwUsing
        case "namespace": type = .kwNamespace
        case "true": type = .kwTrue
        case "false": type = .kwFalse
        case "NULL": type = .kwNull
        case "nullptr": type = .kwNullptr
        default:
            type = .identifier(word)
        }
        
        return CToken(type: type, location: startLoc, raw: word)
    }
}
