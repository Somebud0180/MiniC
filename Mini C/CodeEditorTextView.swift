import UIKit
import SwiftUI

struct CodeEditorTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var textInserter: ((String) -> Void)?
    var bottomPadding: CGFloat = 80
    var onTextChange: (() -> Void)?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> CodeEditorContainerView {
        let container = CodeEditorContainerView()
        container.bottomPadding = bottomPadding
        container.textView.delegate = context.coordinator
        
        let coordinator = context.coordinator
        container.onTextChanged = { [weak coordinator] newText in
            guard let coordinator = coordinator else { return }
            if coordinator.parent.text != newText {
                coordinator.parent.text = newText
                coordinator.parent.onTextChange?()
            }
        }
        
        DispatchQueue.main.async {
            self.textInserter = { stringToInsert in
                container.insertTextAtCursor(stringToInsert)
            }
        }
        
        container.setText(text)
        return container
    }
    
    func updateUIView(_ uiView: CodeEditorContainerView, context: Context) {
        context.coordinator.parent = self
        
        if uiView.bottomPadding != bottomPadding {
            uiView.bottomPadding = bottomPadding
            uiView.updateInsetsAndGutter()
        }
        
        if uiView.textView.text != text {
            uiView.setText(text)
        }
        
        if isFocused && !uiView.textView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.textView.becomeFirstResponder()
            }
        } else if !isFocused && uiView.textView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.textView.resignFirstResponder()
            }
        }
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorTextView
        
        init(_ parent: CodeEditorTextView) {
            self.parent = parent
        }
        
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onTextChange?()
            if let container = textView.superview as? CodeEditorContainerView {
                container.updateLineNumbers()
                container.scrollToCursor()
            }
        }
        
        func textViewDidChangeSelection(_ textView: UITextView) {
            if let container = textView.superview as? CodeEditorContainerView {
                container.scrollToCursor()
            }
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
            if let container = textView.superview as? CodeEditorContainerView {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    container.scrollToCursor()
                }
            }
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let textView = scrollView as? UITextView,
               let container = textView.superview as? CodeEditorContainerView {
                container.gutterView.setNeedsDisplay()
            }
        }
    }
}

// MARK: - CodeEditorContainerView

class CodeEditorContainerView: UIView {
    let gutterView = LineNumberGutterView()
    let textView = UITextView()
    private let dividerView = UIView()
    private var gutterWidthConstraint: NSLayoutConstraint?
    private var lastKeyboardFrame: CGRect?
    private var keyboardOverlap: CGFloat = 0
    
    var bottomPadding: CGFloat = 80
    var onTextChanged: ((String) -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupViews() {
        backgroundColor = .systemBackground
        
        // Gutter styling & layout
        gutterView.backgroundColor = UIColor.tertiarySystemBackground
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutterView)
        
        // Divider line
        dividerView.backgroundColor = UIColor.separator
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)
        
        // TextView styling & layout
        textView.backgroundColor = .clear
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = UIColor.label
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        textView.alwaysBounceVertical = true
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.keyboardDismissMode = .interactive
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        
        gutterView.textView = textView
        
        let widthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 40)
        self.gutterWidthConstraint = widthConstraint
        
        NSLayoutConstraint.activate([
            // Gutter spans full container height and pinned to leading edge (extends into safe area)
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            
            // Thin divider
            dividerView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 0.5),
            
            // TextView fills remaining space and extends to trailing edge
            textView.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        
        updateInsetsAndGutter()
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            recomputeKeyboardOverlap()
            updateInsetsAndGutter()
        }
    }
    
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateInsetsAndGutter()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeKeyboardOverlap()
        updateInsetsAndGutter()
    }
    
    private func recomputeKeyboardOverlap() {
        guard let keyboardFrame = lastKeyboardFrame, window != nil else {
            keyboardOverlap = 0
            return
        }
        let keyboardFrameInView = convert(keyboardFrame, from: nil)
        let overlap = max(0, bounds.maxY - keyboardFrameInView.minY)
        self.keyboardOverlap = overlap
    }
    
    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardEndFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        self.lastKeyboardFrame = keyboardEndFrame
        recomputeKeyboardOverlap()
        
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? (7 << 16)
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw))
        
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            self.updateInsetsAndGutter()
        } completion: { _ in
            if self.textView.isFirstResponder {
                self.scrollToCursor()
            }
        }
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        self.lastKeyboardFrame = nil
        self.keyboardOverlap = 0
        
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? (7 << 16)
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw))
        
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            self.updateInsetsAndGutter()
        }
    }
    
    func updateInsetsAndGutter() {
        let lineCount = max(1, textView.text.components(separatedBy: .newlines).count)
        let digits = String(lineCount).count
        let baseWidth = max(40.0, CGFloat(digits * 10 + 20))
        let totalGutterWidth = baseWidth + safeAreaInsets.left
        
        if gutterWidthConstraint?.constant != totalGutterWidth {
            gutterWidthConstraint?.constant = totalGutterWidth
        }
        
        let effectiveBottomInset = bottomPadding + max(safeAreaInsets.bottom, keyboardOverlap)
        let rightInset = 8.0 + safeAreaInsets.right
        let newInsets = UIEdgeInsets(top: 12, left: 8, bottom: effectiveBottomInset, right: rightInset)
        if textView.textContainerInset != newInsets {
            textView.textContainerInset = newInsets
        }
        
        let scrollInsets = UIEdgeInsets(top: 0, left: 0, bottom: effectiveBottomInset, right: safeAreaInsets.right)
        if textView.verticalScrollIndicatorInsets != scrollInsets {
            textView.verticalScrollIndicatorInsets = scrollInsets
        }
        
        gutterView.setNeedsDisplay()
    }
    
    func scrollToCursor() {
        guard textView.isFirstResponder,
              let selectedRange = textView.selectedTextRange else { return }
        let caretRect = textView.caretRect(for: selectedRange.end)
        guard !caretRect.isNull && !caretRect.isInfinite else { return }
        
        let bottomClearance = bottomPadding + max(safeAreaInsets.bottom, keyboardOverlap)
        let visibleHeight = bounds.height - bottomClearance
        guard visibleHeight > 0 else { return }
        
        let caretY = caretRect.origin.y
        let currentOffsetY = textView.contentOffset.y
        let relativeCaretY = caretY - currentOffsetY
        
        if relativeCaretY > visibleHeight - caretRect.height - 16 {
            let targetOffsetY = caretY - (visibleHeight - caretRect.height - 16)
            let maxOffsetY = max(0, textView.contentSize.height - bounds.height + bottomClearance)
            let clampedOffsetY = min(targetOffsetY, maxOffsetY)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffsetY), animated: true)
        } else if relativeCaretY < 8 {
            let targetOffsetY = max(0, caretY - 8)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: targetOffsetY), animated: true)
        }
    }
    
    func setText(_ text: String) {
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.text = text
            if selectedRange.location + selectedRange.length <= text.utf16.count {
                textView.selectedRange = selectedRange
            }
        }
        updateLineNumbers()
    }
    
    func updateLineNumbers() {
        updateInsetsAndGutter()
    }
    
    func insertTextAtCursor(_ string: String) {
        textView.insertText(string)
        onTextChanged?(textView.text)
        updateLineNumbers()
        scrollToCursor()
    }
}

// MARK: - LineNumberGutterView

class LineNumberGutterView: UIView {
    weak var textView: UITextView?
    
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        
        guard let textView = textView else { return }
        let layoutManager = textView.layoutManager
        
        let context = UIGraphicsGetCurrentContext()
        context?.clear(rect)
        
        // Full height gutter background fill (extends beyond safe area to edge/notch)
        UIColor.tertiarySystemBackground.setFill()
        context?.fill(rect)
        
        let visibleRect = textView.bounds
        let contentOffset = textView.contentOffset
        let topInset = textView.textContainerInset.top
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel
        ]
        
        let string = textView.text as NSString
        let numberOfGlyphs = layoutManager.numberOfGlyphs
        let minX = safeAreaInsets.left + 4
        
        if string.length == 0 {
            let lineString = "1" as NSString
            let textSize = lineString.size(withAttributes: attributes)
            let xPosition = max(minX, bounds.width - textSize.width - 8)
            let lineRect = layoutManager.extraLineFragmentRect
            let yPosition = lineRect.origin.y + topInset - contentOffset.y
            let drawRect = CGRect(
                x: xPosition,
                y: yPosition + max(0, (lineRect.height - textSize.height) / 2.0),
                width: textSize.width,
                height: textSize.height
            )
            lineString.draw(in: drawRect, withAttributes: attributes)
            return
        }
        
        var lineIndex = 1
        var glyphIndex = 0
        
        while glyphIndex < numberOfGlyphs {
            let lineRange = string.lineRange(for: NSRange(location: glyphIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            
            var lineFragmentRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: &lineFragmentRange)
            
            let yPosition = lineRect.origin.y + topInset - contentOffset.y
            
            // Render line number if visible within viewport
            if yPosition + lineRect.height >= 0 && yPosition <= visibleRect.height {
                let lineString = "\(lineIndex)" as NSString
                let textSize = lineString.size(withAttributes: attributes)
                let xPosition = max(minX, bounds.width - textSize.width - 8)
                
                let drawRect = CGRect(
                    x: xPosition,
                    y: yPosition + (lineRect.height - textSize.height) / 2.0,
                    width: textSize.width,
                    height: textSize.height
                )
                lineString.draw(in: drawRect, withAttributes: attributes)
            }
            
            lineIndex += 1
            glyphIndex = NSMaxRange(lineRange)
        }
        
        // Render final line number if text ends with a newline
        if string.length > 0 && string.hasSuffix("\n") {
            let lastGlyphIndex = max(0, numberOfGlyphs - 1)
            let lastLineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
            let yPosition = lastLineRect.maxY + topInset - contentOffset.y
            
            if yPosition + 20 >= 0 && yPosition <= visibleRect.height {
                let lineString = "\(lineIndex)" as NSString
                let textSize = lineString.size(withAttributes: attributes)
                let xPosition = max(minX, bounds.width - textSize.width - 8)
                
                let drawRect = CGRect(
                    x: xPosition,
                    y: yPosition,
                    width: textSize.width,
                    height: textSize.height
                )
                lineString.draw(in: drawRect, withAttributes: attributes)
            }
        }
    }
}
