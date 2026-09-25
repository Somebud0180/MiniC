import SwiftUI

struct ContentView: View {
    /// The root folder URL being browsed (defaults to documents directory).
    let initialFolderURL: URL
    
    @State private var selectedFileURL: URL? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    
    init(folderURL: URL? = nil) {
        self.initialFolderURL = folderURL ?? FileManagerService.shared.documentsDirectory
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            NavigationStack {
                FolderExplorerView(
                    folderURL: initialFolderURL,
                    selectedFileURL: $selectedFileURL,
                    preferredCompactColumn: $preferredCompactColumn
                )
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            Group {
                if let selectedFileURL {
                    CodeEditorView(fileURL: selectedFileURL)
                        .id(selectedFileURL)
                } else {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Folder Explorer View (Sidebar)

struct FolderExplorerView: View {
    let folderURL: URL
    @Binding var selectedFileURL: URL?
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    
    @State private var items: [FileItem] = []
    @State private var searchText: String = ""
    
    // Dialog & Alert states
    @State private var showCreateFileDialog: Bool = false
    @State private var showCreateFolderDialog: Bool = false
    @State private var newFileName: String = ""
    @State private var newFileType: FileType = .c
    @State private var newFolderName: String = ""
    
    // Rename states
    @State private var itemToRename: FileItem? = nil
    @State private var renameInput: String = ""
    
    // Delete states
    @State private var itemToDelete: FileItem? = nil
    @State private var showDeleteConfirmation: Bool = false
    
    // Error state
    @State private var alertErrorMessage: String? = nil
    @State private var showAlertError: Bool = false
    @State private var showSettingsSheet: Bool = false
    
    var isRootDirectory: Bool {
        folderURL.path == FileManagerService.shared.documentsDirectory.path
    }
    
    var filteredItems: [FileItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return items
        }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        explorerList
            .navigationTitle(isRootDirectory ? "Mini C" : folderURL.lastPathComponent)
            .navigationBarTitleDisplayMode(isRootDirectory ? .large : .inline)
            .refreshable {
                loadItems()
            }
            .searchable(text: $searchText, prompt: "Search files and folders")
            .task {
                loadItems()
            }
    }
    
    private var explorerList: some View {
        List {
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                Section {
                    ForEach(filteredItems) { item in
                        if item.isDirectory {
                            NavigationLink(value: item) {
                                FolderRowView(item: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                deleteButton(for: item)
                                renameButton(for: item)
                                duplicateButton(for: item)
                            }
                            .contextMenu {
                                contextMenuItems(for: item)
                            }
                        } else {
                            Button {
                                selectedFileURL = item.url
                                preferredCompactColumn = .detail
                            } label: {
                                FileRowView(item: item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                selectedFileURL == item.url ? Color.accentColor.opacity(0.15) : nil
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                deleteButton(for: item)
                                renameButton(for: item)
                                duplicateButton(for: item)
                            }
                            .contextMenu {
                                contextMenuItems(for: item)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(filteredItems.count) item\(filteredItems.count == 1 ? "" : "s")")
                        Spacer()
                        if !isRootDirectory {
                            Text(folderURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: FileItem.self) { item in
            if item.isDirectory {
                FolderExplorerView(
                    folderURL: item.url,
                    selectedFileURL: $selectedFileURL,
                    preferredCompactColumn: $preferredCompactColumn
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: {
                    showSettingsSheet = true
                }) {
                    Image(systemName: "gearshape")
                }
                
                Menu {
                    Button(action: {
                        newFileName = ""
                        newFileType = .c
                        showCreateFileDialog = true
                    }) {
                        Label("New File", systemImage: "doc.badge.plus")
                    }
                    
                    Button(action: {
                        newFolderName = ""
                        showCreateFolderDialog = true
                    }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }
        .sheet(isPresented: $showCreateFileDialog) {
            createFileSheet
                .presentationDetents([.medium])
        }
        .alert("New Folder", isPresented: $showCreateFolderDialog) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                createFolder()
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert("Rename Item", isPresented: Binding(
            get: { itemToRename != nil },
            set: { if !$0 { itemToRename = nil } }
        )) {
            TextField("New Name", text: $renameInput)
            Button("Cancel", role: .cancel) { itemToRename = nil }
            Button("Rename") {
                performRename()
            }
        } message: {
            Text("Enter a new name for '\(itemToRename?.name ?? "")'.")
        }
        .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { itemToDelete = nil }
            Button("Delete", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("Are you sure you want to delete '\(itemToDelete?.name ?? "")'? This action cannot be undone.")
        }
        .alert("Error", isPresented: $showAlertError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertErrorMessage ?? "An unknown error occurred.")
        }
    }
    
    // MARK: - Row Views
    
    private struct FolderRowView: View {
        let item: FileItem
        
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    Text("Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
    
    private struct FileRowView: View {
        let item: FileItem
        
        var body: some View {
            HStack(spacing: 12) {
                if let type = item.fileType {
                    Image(systemName: type.systemIcon)
                        .font(.title2)
                        .foregroundStyle(type.badgeColor)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name)
                            .font(.body)
                            .fontWeight(.medium)
                        
                        if let type = item.fileType {
                            Text(type.extensionName.uppercased())
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(type.badgeColor.opacity(0.15))
                                .foregroundStyle(type.badgeColor)
                                .clipShape(Capsule())
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Text(item.formattedSize)
                        Text("•")
                        Text(item.formattedDate)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
    
    // MARK: - Context & Action Buttons
    
    @ViewBuilder
    private func contextMenuItems(for item: FileItem) -> some View {
        Button {
            startRename(for: item)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        
        Button {
            duplicate(item: item)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        
        if !item.isDirectory {
            ShareLink(item: item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        
        Divider()
        
        Button(role: .destructive) {
            itemToDelete = item
            showDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    
    private func deleteButton(for item: FileItem) -> some View {
        Button(role: .destructive) {
            itemToDelete = item
            showDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    
    private func renameButton(for item: FileItem) -> some View {
        Button {
            startRename(for: item)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .tint(.orange)
    }
    
    private func duplicateButton(for item: FileItem) -> some View {
        Button {
            duplicate(item: item)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .tint(.blue)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("No Files or Folders")
                .font(.headline)
            
            Text("Create your first C or C++ source file or create a folder to organize your code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 12) {
                Button(action: {
                    newFileName = ""
                    newFileType = .c
                    showCreateFileDialog = true
                }) {
                    Label("New .c", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                
                Button(action: {
                    newFileName = ""
                    newFileType = .cpp
                    showCreateFileDialog = true
                }) {
                    Label("New .cpp", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                
                Button(action: {
                    newFolderName = ""
                    showCreateFolderDialog = true
                }) {
                    Label("Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }
    
    // MARK: - Sheets
    
    private var createFileSheet: some View {
        NavigationStack {
            Form {
                Section("File Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("main", text: $newFileName)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                    }
                    
                    Picker("File Type", selection: $newFileType) {
                        ForEach(FileType.allCases) { fileType in
                            Text(fileType.displayName).tag(fileType)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Preview Extension") {
                    HStack {
                        Text("Full Name")
                        Spacer()
                        Text(formattedNewFileName)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button(action: createFile) {
                    Text("Create File")
                        .fontWeight(.semibold)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(newFileType.badgeColor)
            }
            .navigationTitle("New Code File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCreateFileDialog = false
                    }
                }
            }
        }
    }
    
    private var formattedNewFileName: String {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "main" : name
        let ext = ".\(newFileType.extensionName)"
        return base.lowercased().hasSuffix(ext) ? base : base + ext
    }
    
    // MARK: - Helper Actions
    
    private func loadItems() {
        items = FileManagerService.shared.contentsOfDirectory(at: folderURL)
    }
    
    private func createFile() {
        do {
            let createdURL = try FileManagerService.shared.createFile(name: newFileName, type: newFileType, in: folderURL)
            showCreateFileDialog = false
            loadItems()
            selectedFileURL = createdURL
            preferredCompactColumn = .detail
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func createFolder() {
        do {
            try FileManagerService.shared.createFolder(name: newFolderName, in: folderURL)
            showCreateFolderDialog = false
            loadItems()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func startRename(for item: FileItem) {
        itemToRename = item
        renameInput = item.name
    }
    
    private func performRename() {
        guard let item = itemToRename else { return }
        do {
            let newURL = try FileManagerService.shared.renameItem(at: item.url, to: renameInput)
            if selectedFileURL == item.url {
                selectedFileURL = newURL
            }
            itemToRename = nil
            loadItems()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func performDelete() {
        guard let item = itemToDelete else { return }
        do {
            try FileManagerService.shared.deleteItem(at: item.url)
            if selectedFileURL == item.url || (item.isDirectory && selectedFileURL?.path.hasPrefix(item.url.path) == true) {
                selectedFileURL = nil
            }
            itemToDelete = nil
            loadItems()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func duplicate(item: FileItem) {
        do {
            try FileManagerService.shared.duplicateItem(at: item.url)
            loadItems()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func showError(_ message: String) {
        alertErrorMessage = message
        showAlertError = true
    }
}

#Preview {
    ContentView()
}
