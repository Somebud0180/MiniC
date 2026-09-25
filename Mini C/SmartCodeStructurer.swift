import SwiftUI
import UIKit
import Observation

// MARK: - Editor Settings

@Observable final class EditorSettings {
    static let shared = EditorSettings()
    
    var autoIndent: Bool {
        didSet { UserDefaults.standard.set(autoIndent, forKey: "editor_auto_indent") }
    }
    var autoBrackets: Bool {
        didSet { UserDefaults.standard.set(autoBrackets, forKey: "editor_auto_brackets") }
    }
    var autoDeletePairs: Bool {
        didSet { UserDefaults.standard.set(autoDeletePairs, forKey: "editor_auto_delete_pairs") }
    }
    var indentWithSpaces: Bool {
        didSet { UserDefaults.standard.set(indentWithSpaces, forKey: "editor_indent_spaces") }
    }
    var indentWidth: Int {
        didSet { UserDefaults.standard.set(indentWidth, forKey: "editor_indent_width") }
    }
    var wrapSelection: Bool {
        didSet { UserDefaults.standard.set(wrapSelection, forKey: "editor_wrap_selection") }
    }
    var autoDedent: Bool {
        didSet { UserDefaults.standard.set(autoDedent, forKey: "editor_auto_dedent") }
    }
    var trimTrailingWhitespace: Bool {
        didSet { UserDefaults.standard.set(trimTrailingWhitespace, forKey: "editor_trim_trailing_whitespace") }
    }
    var autoSave: Bool {
        didSet { UserDefaults.standard.set(autoSave, forKey: "editor_auto_save") }
    }
    var formatOnSave: Bool {
        didSet { UserDefaults.standard.set(formatOnSave, forKey: "editor_format_on_save") }
    }
    
    init() {
        UserDefaults.standard.register(defaults: [
            "editor_auto_indent": true,
            "editor_auto_brackets": true,
            "editor_auto_delete_pairs": true,
            "editor_indent_spaces": false,
            "editor_indent_width": 4,
            "editor_wrap_selection": true,
            "editor_auto_dedent": true,
            "editor_trim_trailing_whitespace": true,
            "editor_auto_save": true,
            "editor_format_on_save": false
        ])
        
        self.autoIndent = UserDefaults.standard.bool(forKey: "editor_auto_indent")
        self.autoBrackets = UserDefaults.standard.bool(forKey: "editor_auto_brackets")
        self.autoDeletePairs = UserDefaults.standard.bool(forKey: "editor_auto_delete_pairs")
        self.indentWithSpaces = UserDefaults.standard.bool(forKey: "editor_indent_spaces")
        let savedWidth = UserDefaults.standard.integer(forKey: "editor_indent_width")
        self.indentWidth = savedWidth == 0 ? 4 : savedWidth
        self.wrapSelection = UserDefaults.standard.bool(forKey: "editor_wrap_selection")
        self.autoDedent = UserDefaults.standard.bool(forKey: "editor_auto_dedent")
        self.trimTrailingWhitespace = UserDefaults.standard.bool(forKey: "editor_trim_trailing_whitespace")
        self.autoSave = UserDefaults.standard.bool(forKey: "editor_auto_save")
        self.formatOnSave = UserDefaults.standard.bool(forKey: "editor_format_on_save")
    }
    
    var indentUnit: String {
        if indentWithSpaces {
            return String(repeating: " ", count: max(1, indentWidth))
        } else {
            return "\t"
        }
    }
}

// MARK: - Smart Edit Result

enum SmartEditResult {
    case unhandled
    case handled(targetRange: NSRange, replacement: String, cursorLocation: Int)
    case moveCursor(newLocation: Int)
}

// MARK: - Smart Code Structurer

struct SmartCodeStructurer {
    static let bracketPairs: [String: String] = [
        "(": ")",
        "{": "}",
        "[": "]",
        "\"": "\"",
        "'": "'"
    ]
    
    static let closingBrackets: Set<Character> = [")", "}", "]", "\"", "'"]
    
    /// Handle a keystroke or quick-key insertion in a UITextView.
    static func handleKeystroke(
        textView: UITextView,
        range: NSRange,
        replacementText text: String,
        settings: EditorSettings = .shared
    ) -> SmartEditResult {
        let fullText = (textView.text ?? "") as NSString
        
        // 1. Enter / Newline Auto-Indent
        if text == "\n" && settings.autoIndent {
            return handleNewline(fullText: fullText, range: range, settings: settings)
        }
        
        // 2. Wrap Selection with Brackets / Quotes
        if range.length > 0 && settings.wrapSelection,
           let closing = bracketPairs[text] {
            let selectedText = fullText.substring(with: range)
            let wrapped = text + selectedText + closing
            return .handled(targetRange: range, replacement: wrapped, cursorLocation: range.location + wrapped.utf16.count)
        }
        
        // 3. Skip over closing bracket if typed right before it
        if text.count == 1, closingBrackets.contains(Character(text)), range.length == 0 {
            if range.location < fullText.length {
                let nextChar = fullText.substring(with: NSRange(location: range.location, length: 1))
                if nextChar == text {
                    return .moveCursor(newLocation: range.location + 1)
                }
            }
        }
        
        // 4. Auto-closing brackets / quotes
        if range.length == 0 && settings.autoBrackets,
           let closing = bracketPairs[text] {
            // For quotes, don't auto-close if preceded by an alphanumeric character (e.g. contractions or identifier)
            if (text == "'" || text == "\"") && range.location > 0 {
                let prevChar = fullText.substring(with: NSRange(location: range.location - 1, length: 1))
                if let first = prevChar.first, first.isLetter || first.isNumber {
                    return .unhandled
                }
            }
            let pair = text + closing
            return .handled(targetRange: range, replacement: pair, cursorLocation: range.location + text.utf16.count)
        }
        
        // 5. Backspace pair deletion
        if text.isEmpty && range.length == 1 && settings.autoDeletePairs {
            let charToDelete = fullText.substring(with: range)
            if let expectedClosing = bracketPairs[charToDelete] {
                let nextIndex = range.location + 1
                if nextIndex <= fullText.length {
                    let nextChar = fullText.substring(with: NSRange(location: range.location, length: 1))
                    if nextChar == expectedClosing {
                        // Delete both the opening char and its adjacent closing char
                        let pairRange = NSRange(location: range.location, length: 2)
                        return .handled(targetRange: pairRange, replacement: "", cursorLocation: range.location)
                    }
                }
            }
        }
        
        // 6. Tab key -> Spaces conversion
        if text == "\t" && settings.indentWithSpaces {
            return .handled(targetRange: range, replacement: settings.indentUnit, cursorLocation: range.location + settings.indentUnit.utf16.count)
        }
        
        // 7. Auto-dedent on typing '}' on an indent-only line
        if text == "}" && settings.autoDedent && range.length == 0 {
            let lineRange = fullText.lineRange(for: NSRange(location: range.location, length: 0))
            let prefixToCursor = fullText.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            
            if prefixToCursor.allSatisfy({ $0 == " " || $0 == "\t" }) && !prefixToCursor.isEmpty {
                let indent = settings.indentUnit
                if prefixToCursor.hasSuffix(indent) {
                    let dedentedLength = prefixToCursor.count - indent.count
                    let targetRange = NSRange(location: lineRange.location + dedentedLength, length: indent.count)
                    return .handled(targetRange: targetRange, replacement: "}", cursorLocation: lineRange.location + dedentedLength + 1)
                }
            }
        }
        
        return .unhandled
    }
    
    private static func handleNewline(
        fullText: NSString,
        range: NSRange,
        settings: EditorSettings
    ) -> SmartEditResult {
        let lineRange = fullText.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = fullText.substring(with: lineRange)
        
        // Compute base indentation of current line
        var currentIndent = ""
        for char in lineText {
            if char == " " || char == "\t" {
                currentIndent.append(char)
            } else {
                break
            }
        }
        
        // Text on the line up to the cursor
        let prefixToCursor = fullText.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
        let trimmedPrefix = prefixToCursor.trimmingCharacters(in: .whitespaces)
        
        // Check if cursor is between '{' and '}'
        let isOpeningBraceBefore = trimmedPrefix.hasSuffix("{") || trimmedPrefix.hasSuffix("(") || trimmedPrefix.hasSuffix("[")
        var isClosingBraceAfter = false
        if range.location < fullText.length {
            let nextChar = fullText.substring(with: NSRange(location: range.location, length: 1))
            if nextChar == "}" || nextChar == ")" || nextChar == "]" {
                isClosingBraceAfter = true
            }
        }
        
        if isOpeningBraceBefore && isClosingBraceAfter {
            // Expand:
            // {
            //     <cursor>
            // }
            let innerIndent = currentIndent + settings.indentUnit
            let replacement = "\n" + innerIndent + "\n" + currentIndent
            let cursorLoc = range.location + 1 + innerIndent.utf16.count
            return .handled(targetRange: range, replacement: replacement, cursorLocation: cursorLoc)
        } else if isOpeningBraceBefore || trimmedPrefix.hasSuffix(":") {
            // Increase indentation level
            let nextIndent = currentIndent + settings.indentUnit
            let replacement = "\n" + nextIndent
            return .handled(targetRange: range, replacement: replacement, cursorLocation: range.location + replacement.utf16.count)
        } else {
            // Preserve current indentation
            let replacement = "\n" + currentIndent
            return .handled(targetRange: range, replacement: replacement, cursorLocation: range.location + replacement.utf16.count)
        }
    }
}

// MARK: - C / C++ Code Prettifier

struct CodeFormatter {
    /// Formats C/C++ source code with smart indentation and structure.
    static func prettify(_ source: String, settings: EditorSettings = .shared) -> String {
        let lines = source.components(separatedBy: "\n")
        let indentUnit = settings.indentUnit
        var formattedLines: [String] = []
        var indentLevel = 0
        var inMultiLineComment = false
        var consecutiveEmptyLines = 0
        
        for rawLine in lines {
            let line = settings.trimTrailingWhitespace ? rawLine.trimmingCharacters(in: .whitespaces) : rawLine
            
            // Handle consecutive empty lines
            if line.isEmpty {
                consecutiveEmptyLines += 1
                if consecutiveEmptyLines <= 1 {
                    formattedLines.append("")
                }
                continue
            }
            consecutiveEmptyLines = 0
            
            // Handle multi-line comments
            if inMultiLineComment {
                let indentString = String(repeating: indentUnit, count: max(0, indentLevel))
                formattedLines.append(indentString + " " + line)
                if line.contains("*/") {
                    inMultiLineComment = false
                }
                continue
            }
            
            if line.hasPrefix("/*") && !line.contains("*/") {
                inMultiLineComment = true
                let indentString = String(repeating: indentUnit, count: max(0, indentLevel))
                formattedLines.append(indentString + line)
                continue
            }
            
            // Keep preprocessor directives at root column
            if line.hasPrefix("#") {
                formattedLines.append(line)
                continue
            }
            
            // Calculate bracket balance on line without string/char literals
            let (_, openCount, closeCount, leadingCloseCount) = analyzeBraces(in: line)
            
            // Dedent before line if line starts with closing brace or label/case
            var effectiveIndent = indentLevel
            if leadingCloseCount > 0 {
                effectiveIndent = max(0, indentLevel - leadingCloseCount)
            } else if line.hasPrefix("case ") || line.hasPrefix("default:") {
                effectiveIndent = max(0, indentLevel - 1)
            }
            
            let indentString = String(repeating: indentUnit, count: effectiveIndent)
            formattedLines.append(indentString + line)
            
            // Update indent level for following lines
            indentLevel = max(0, indentLevel + openCount - closeCount)
        }
        
        return formattedLines.joined(separator: "\n")
    }
    
    private static func analyzeBraces(in line: String) -> (cleanLine: String, openBraces: Int, closeBraces: Int, leadingClose: Int) {
        var clean = ""
        var inString = false
        var inChar = false
        var isEscaped = false
        var openBraces = 0
        var closeBraces = 0
        var leadingClose = 0
        var checkingLeading = true
        
        for char in line {
            if isEscaped {
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" && !inChar {
                inString.toggle()
                continue
            }
            if char == "'" && !inString {
                inChar.toggle()
                continue
            }
            if inString || inChar {
                continue
            }
            
            // Single-line comment ends brace counting for line
            if clean.hasSuffix("/") && char == "/" {
                break
            }
            
            if char == "{" {
                openBraces += 1
                checkingLeading = false
            } else if char == "}" {
                closeBraces += 1
                if checkingLeading {
                    leadingClose += 1
                }
            } else if !char.isWhitespace {
                checkingLeading = false
            }
            
            clean.append(char)
        }
        
        return (clean, openBraces, closeBraces, leadingClose)
    }
}
