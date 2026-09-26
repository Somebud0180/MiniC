import SwiftUI

struct CodeEditorView: View {
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @ObservedObject var terminalViewModel: TerminalViewModel = TerminalViewModel()
    let fileURL: URL
    var onOpen: ((String, String) -> Void)? = nil
    var onRun: ((String, String) -> Void)? = nil
    var onToggleTerminal: (() -> Void)? = nil
    
    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var isEditorFocused: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showSaveSuccess: Bool = false
    @State private var showPrettifyFeedback: Bool = false
    @State private var showDetailsSheet: Bool = false
    @State private var isHeaderCollapsed: Bool = false
    @State private var autosaveTask: Task<Void, Never>? = nil
    
    // Reference handler to insert text at cursor position in editor
    @State private var textInserter: ((String) -> Void)? = nil
    
    private var fileItem: FileItem {
        let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        return FileItem(
            url: fileURL,
            isDirectory: false,
            modificationDate: values?.contentModificationDate,
            size: Int64(values?.fileSize ?? 0)
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading file...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage {
                ContentUnavailableView(
                    "Failed to Open File",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                codeEditorBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                    .overlay(alignment: .bottom) {
                        codeEditorToolbar
                    }
                    .overlay(alignment: .top) {
                        if showPrettifyFeedback {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.purple)
                                Text("Code Prettified")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .onAppear {
                        onOpen?(content, fileURL.lastPathComponent)
                    }
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { topToolbar }
        .toolbar(isHeaderCollapsed && verticalSizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .task {
            loadFileContent()
        }
        .sheet(isPresented: $showDetailsSheet) {
            fileDetailsSheet
                .presentationDetents([.medium])
        }
        .onChange(of: isEditorFocused) {
            withAnimation(.smooth) {
                isHeaderCollapsed = isEditorFocused
            }
        }
        .onDisappear {
            autosaveTask?.cancel()
            if content != originalContent && !isSaving {
                saveChanges()
            }
        }
    }
    
    // MARK: - Navigation Toolbar
    private var topToolbar: some ToolbarContent {
        Group {
            if #available(anyAppleOS 27.0, *) {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Run / Stop Execution Button
                    Button(action: {
                        if content != originalContent && !isSaving {
                            saveChanges()
                        }
                        if terminalViewModel.isRunning {
                            terminalViewModel.stop()
                        } else {
                            onRun?(content, fileURL.lastPathComponent)
                        }
                    }) {
                        if terminalViewModel.isRunning {
                            Label("Stop", systemImage: "stop.fill")
                                .foregroundStyle(.red)
                        } else {
                            Label("Run", systemImage: "play.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .help(terminalViewModel.isRunning ? "Stop Execution" : "Run Program")
                    
                    // Terminal Toggle
                    Button(action: {
                        onToggleTerminal?()
                    }) {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .help("Toggle Terminal")
                    
                    Button(action: prettifyContent) {
                        Label("Prettify", systemImage: "wand.and.sparkles")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(isLoading || isSaving)
                    
                    Button(action: saveChanges) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .disabled(content == originalContent || isSaving)
                }
                
                ToolbarOverflowMenu {
                    ShareLink(item: fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    
                    Button(action: { showDetailsSheet = true }) {
                        Label("File Info", systemImage: "info.circle")
                            .labelStyle(.iconOnly)
                    }
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Run / Stop Execution Button
                    Button(action: {
                        if content != originalContent && !isSaving {
                            saveChanges()
                        }
                        if terminalViewModel.isRunning {
                            terminalViewModel.stop()
                        } else {
                            onRun?(content, fileURL.lastPathComponent)
                        }
                    }) {
                        if terminalViewModel.isRunning {
                            Label("Stop", systemImage: "stop.fill")
                                .foregroundStyle(.red)
                        } else {
                            Label("Run", systemImage: "play.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .help(terminalViewModel.isRunning ? "Stop Execution" : "Run Program")
                    
                    // Terminal Toggle
                    Button(action: {
                        onToggleTerminal?()
                    }) {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .help("Toggle Terminal")
                    
                    Button(action: prettifyContent) {
                        Label("Prettify", systemImage: "wand.and.sparkles")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(isLoading || isSaving)
                    
                    Button(action: saveChanges) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .disabled(content == originalContent || isSaving)
                    
                    Menu {
                        ShareLink(item: fileURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                        
                        Button(action: { showDetailsSheet = true }) {
                            Label("File Info", systemImage: "info.circle")
                                .labelStyle(.iconOnly)
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
    }
    
    // MARK: - Keyboard Toolbar
    private var codeEditorToolbar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Horizontally scrollable quick keys
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 10) {
                    // Grouped key pairs (C/C++ brackets, parens, braces, quotes, etc.)
                    keyPairGroup(left: "{", right: "}")
                    keyPairGroup(left: "(", right: ")")
                    keyPairGroup(left: "[", right: "]")
                    keyPairGroup(left: "<", right: ">")
                    keyPairGroup(left: "\"", right: "\"")
                    keyPairGroup(left: "'", right: "'")
                    
                    // Essential C/C++ operators and punctuation
                    keyGroup(["\t", ";", ",", "=", "->", "::", "#"])
                    
                    // Arithmetic & Bitwise/Logical operators
                    keyGroup(["+", "-", "*", "/", "%", "&", "|", "!"])
                }
                .padding(.trailing, 8)
            }
            .clipShape(Capsule())
            
            // Vertical Divider separating scrollable keys from pinned toggle
            Divider()
                .frame(height: 22)
                .padding(.horizontal, 6)
            
            // Pinned Keyboard Toggle Button
            Button(action: {
                isEditorFocused.toggle()
            }) {
                Image(systemName: isEditorFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(minWidth: 40, minHeight: 36, alignment: .center)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 9,
                            bottomLeadingRadius: 9,
                            bottomTrailingRadius: 18,
                            topTrailingRadius: 18,
                            style: .continuous
                        )
                        .fill(Color(uiColor: .secondarySystemFill))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .glassEffect(in: Capsule())
        .padding(.horizontal, 12)
        .safeAreaPadding(.bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    // MARK: - Key Helpers
    
    private func keyButton(_ symbol: String, isLeft: Bool = false, isRight: Bool = false) -> some View {
        Button(action: {
            insertText(symbol)
        }) {
            Text(labelForSymbol(symbol))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 36, minHeight: 36, alignment: .center)
                .padding(.horizontal, 6)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: isLeft ? 18 : isRight ? 0 : 9,
                        bottomLeadingRadius: isLeft ? 18 : isRight ? 0 : 9,
                        bottomTrailingRadius: isRight ? 18 : isLeft ? 0 : 9,
                        topTrailingRadius: isRight ? 18 : isLeft ? 0 : 9,
                        style: .continuous
                    )
                    .fill(Color(uiColor: .secondarySystemFill))
                )
        }
        .buttonStyle(.plain)
    }
    
    private func keyPairGroup(left: String, right: String) -> some View {
        HStack(spacing: 3) {
            keyButton(left, isLeft: true)
            keyButton(right, isRight: true)
        }
    }
    
    private func keyGroup(_ symbols: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                keyButton(symbol)
            }
        }
    }
    
    private func labelForSymbol(_ symbol: String) -> String {
        switch symbol {
        case "\t": return "⇥"
        default: return symbol
        }
    }
    
    private func insertText(_ textToInsert: String) {
        if let inserter = textInserter {
            inserter(textToInsert)
        } else {
            content.append(textToInsert)
        }
        isEditorFocused = true
    }
    
    private var codeEditorBody: some View {
        VStack(spacing: 0) {
            // Header stats bar
            HStack {
                if let type = fileItem.fileType {
                    Label(type.displayName, systemImage: type.systemIcon)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(type.badgeColor)
                        .background(type.badgeColor.opacity(0.15), in: Capsule())
                }
                
                Spacer()
                
                Text("\(lineCount) lines • \(characterCount) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .safeAreaPadding(.horizontal)
            .padding(.vertical, 8)
            .frame(minHeight: 24)
            .background(Color(uiColor: .secondarySystemBackground))
            .onTapGesture {
                withAnimation(.smooth) {
                    isHeaderCollapsed = !isHeaderCollapsed
                }
            }
            
            Divider()
            
            // Full-height Code Editor with synced line numbers gutter
            CodeEditorTextView(
                text: $content,
                isFocused: $isEditorFocused,
                textInserter: $textInserter,
                bottomPadding: 80,
                onTextChange: {
                    scheduleAutosave()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private var fileDetailsSheet: some View {
        NavigationStack {
            List {
                Section("File Details") {
                    LabeledContent("File Name", value: fileURL.lastPathComponent)
                    if let type = fileItem.fileType {
                        LabeledContent("Language", value: type.displayName)
                    }
                    LabeledContent("Size", value: fileItem.formattedSize)
                    LabeledContent("Modified", value: fileItem.formattedDate)
                    LabeledContent("Lines", value: "\(lineCount)")
                    LabeledContent("Characters", value: "\(characterCount)")
                }
                
                Section("Location") {
                    Text(fileURL.path)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("File Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showDetailsSheet = false }
                }
            }
        }
    }
    
    private var lineCount: Int {
        content.components(separatedBy: .newlines).count
    }
    
    private var characterCount: Int {
        content.count
    }
    
    private func loadFileContent() {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try FileManagerService.shared.readFileContent(at: fileURL)
            content = loaded
            originalContent = loaded
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
    
    private func saveChanges() {
        if EditorSettings.shared.formatOnSave {
            let formatted = CodeFormatter.prettify(content, settings: .shared)
            if formatted != content {
                content = formatted
            }
        }
        isSaving = true
        do {
            try FileManagerService.shared.saveFileContent(content, to: fileURL)
            originalContent = content
            isSaving = false
            withAnimation {
                showSaveSuccess = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    showSaveSuccess = false
                }
            }
        } catch {
            isSaving = false
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
    
    private func prettifyContent() {
        let formatted = CodeFormatter.prettify(content, settings: .shared)
        if formatted != content {
            withAnimation(.easeInOut(duration: 0.2)) {
                content = formatted
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                showPrettifyFeedback = true
            }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showPrettifyFeedback = false
                }
            }
            scheduleAutosave()
        } else {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    private func scheduleAutosave() {
        guard EditorSettings.shared.autoSave else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if content != originalContent && !isSaving {
                    saveChanges()
                }
            }
        }
    }
}
