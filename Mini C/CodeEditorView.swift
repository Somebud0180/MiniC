import SwiftUI

struct CodeEditorView: View {
    let fileURL: URL
    
    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showSaveSuccess: Bool = false
    @State private var showDetailsSheet: Bool = false
    
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
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else if showSaveSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                
                Button(action: saveChanges) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(content == originalContent || isSaving)
                
                ShareLink(item: fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                
                Button(action: { showDetailsSheet = true }) {
                    Image(systemName: "info.circle")
                }
            }
        }
        .task {
            loadFileContent()
        }
        .sheet(isPresented: $showDetailsSheet) {
            fileDetailsSheet
                .presentationDetents([.medium])
        }
    }
    
    private var codeEditorBody: some View {
        VStack(spacing: 0) {
            // Header stats bar
            HStack {
                if let type = fileItem.fileType {
                    Label(type.displayName, systemImage: type.systemIcon)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(type.badgeColor.opacity(0.15))
                        .foregroundStyle(type.badgeColor)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                Text("\(lineCount) lines • \(characterCount) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            
            Divider()
            
            // Code editor area with line numbers
            HStack(alignment: .top, spacing: 0) {
                // Line numbers
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(1...max(1, lineCount), id: \.self) { lineNum in
                        Text("\(lineNum)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.top, 12)
                .background(Color(uiColor: .tertiarySystemBackground))
                
                Divider()
                
                // Code TextEditor
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .onChange(of: content) { _, _ in
                        scheduleAutosave()
                    }
            }
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
    
    private func scheduleAutosave() {
        // Simple autosave helper
    }
}
