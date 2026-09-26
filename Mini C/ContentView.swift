import SwiftUI

struct ContentView: View {
    /// The root folder URL being browsed (defaults to documents directory).
    let initialFolderURL: URL
    
    @State private var selectedFileURL: URL? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    
    @StateObject private var terminalViewModel = TerminalViewModel()
    
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
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } content: {
            Group {
                if let selectedFileURL {
                    CodeEditorView(
                        terminalViewModel: terminalViewModel,
                        fileURL: selectedFileURL,
                        onOpen: { code, fileName in
                            terminalViewModel.load(code: code, fileName: fileName)
                        },
                        onRun: { code, fileName in
                            terminalViewModel.loadAndRun(code: code, fileName: fileName)
                            withAnimation {
                                columnVisibility = .all
                                preferredCompactColumn = .detail
                            }
                        },
                        onToggleTerminal: {
                            withAnimation {
                                if columnVisibility == .all {
                                    columnVisibility = .doubleColumn
                                } else {
                                    columnVisibility = .all
                                    preferredCompactColumn = .detail
                                }
                            }
                        }
                    )
                    .id(selectedFileURL)
                } else {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "doc.text",
                        description: Text("Select a C or C++ file to begin editing and running.")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 520, max: .infinity)
        } detail: {
            NavigationStack {
                TerminalView(
                    viewModel: terminalViewModel,
                    onClose: {
                        withAnimation {
                            columnVisibility = .doubleColumn
                            preferredCompactColumn = .content
                        }
                    }
                )
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
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
    
    // Move states
    @State private var itemToMove: FileItem? = nil
    @State private var showMoveSheet: Bool = false
    @State private var targetedFolderURL: URL? = nil
    @State private var isParentDropTargeted: Bool = false
    
    // Error state
    @State private var alertErrorMessage: String? = nil
    @State private var showAlertError: Bool = false
    @State private var showSettingsSheet: Bool = false
    
    var isRootDirectory: Bool {
        folderURL.standardizedFileURL.path == FileManagerService.shared.documentsDirectory.standardizedFileURL.path
    }
    
    var parentFolderURL: URL {
        folderURL.deletingLastPathComponent()
    }
    
    var parentFolderName: String {
        if parentFolderURL.standardizedFileURL.path == FileManagerService.shared.documentsDirectory.standardizedFileURL.path {
            return "Mini C"
        }
        return parentFolderURL.lastPathComponent
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
            .searchable(text: $searchText, prompt: "Search files and folders")
            .task {
                loadItems()
            }
            .onAppear {
                loadItems()
            }
            .onChange(of: FileManagerService.shared.directoryChangeCount) {
                loadItems()
            }
    }
    
    private var explorerList: some View {
        List {
            // Drop target banner to move files out when inside a subfolder
            if !isRootDirectory {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.turn.up.left")
                            .font(.headline)
                            .foregroundStyle(isParentDropTargeted ? Color.accentColor : Color.secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Move out to \(parentFolderName)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Drop files here to move them out")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "tray.and.arrow.up")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .listRowBackground(
                        isParentDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let droppedURL = urls.first else { return false }
                        moveItem(at: droppedURL, to: parentFolderURL)
                        return true
                    } isTargeted: { targeted in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isParentDropTargeted = targeted
                        }
                    }
                }
            }
            
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                Section {
                    ForEach(filteredItems) { item in
                        if item.isDirectory {
                            NavigationLink(value: item) {
                                FolderRowView(item: item)
                            }
                            .listRowBackground(
                                targetedFolderURL == item.url ? Color.accentColor.opacity(0.18) : nil
                            )
                            .draggable(item.url)
                            .dropDestination(for: URL.self) { urls, _ in
                                guard let droppedURL = urls.first else { return false }
                                moveItem(at: droppedURL, to: item.url)
                                return true
                            } isTargeted: { targeted in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    targetedFolderURL = targeted ? item.url : nil
                                }
                            }
                            .swipeActions(edge: .leading) {
                                moveSwipeButton(for: item)
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
                                preferredCompactColumn = .content
                            } label: {
                                FileRowView(item: item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .draggable(item.url)
                            .listRowBackground(
                                selectedFileURL == item.url ? Color.accentColor.opacity(0.15) : nil
                            )
                            .swipeActions(edge: .leading) {
                                moveSwipeButton(for: item)
                            }
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
        .refreshable {
            loadItems()
        }
        .contextMenu {
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
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showMoveSheet) {
            if let item = itemToMove {
                MoveItemSheet(
                    item: item,
                    currentFolderURL: folderURL,
                    onMove: { destinationURL in
                        moveItem(at: item.url, to: destinationURL)
                        showMoveSheet = false
                        itemToMove = nil
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
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
        
        Divider()
        
        // Direct action to move out to parent directory when inside a subfolder
        if !isRootDirectory {
            Button {
                moveToParent(item: item)
            } label: {
                Label("Move out to '\(parentFolderName)'", systemImage: "arrow.turn.up.left")
            }
        }
        
        Button {
            startMove(for: item)
        } label: {
            Label("Move...", systemImage: "folder")
        }
        
        if !item.isDirectory {
            Divider()
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
    
    private func moveSwipeButton(for item: FileItem) -> some View {
        Button {
            startMove(for: item)
        } label: {
            Label("Move", systemImage: "folder")
        }
        .tint(.indigo)
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
            
            VStack(spacing: 12) {
                Button(action: {
                    newFileName = ""
                    newFileType = .c
                    showCreateFileDialog = true
                }) {
                    Label("New file", systemImage: "doc.badge.plus")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                
                Button(action: {
                    newFolderName = ""
                    showCreateFolderDialog = true
                }) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.borderedProminent)
                .tint(.secondary)
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
            preferredCompactColumn = .content
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
            if selectedFileURL?.standardizedFileURL.path == item.url.standardizedFileURL.path {
                selectedFileURL = newURL
            }
            itemToRename = nil
            loadItems()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func startMove(for item: FileItem) {
        itemToMove = item
        showMoveSheet = true
    }
    
    private func moveToParent(item: FileItem) {
        guard !isRootDirectory else { return }
        moveItem(at: item.url, to: parentFolderURL)
    }
    
    private func moveItem(at sourceURL: URL, to destinationFolderURL: URL) {
        do {
            let newURL = try FileManagerService.shared.moveItem(at: sourceURL, to: destinationFolderURL)
            updateSelectedFileAfterMove(from: sourceURL, to: newURL)
            loadItems()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func updateSelectedFileAfterMove(from sourceURL: URL, to destinationURL: URL) {
        let sourceStandardized = sourceURL.standardizedFileURL
        let destStandardized = destinationURL.standardizedFileURL
        
        if let currentSelected = selectedFileURL?.standardizedFileURL {
            if currentSelected.path == sourceStandardized.path {
                selectedFileURL = destStandardized
            } else if currentSelected.path.hasPrefix(sourceStandardized.path + "/") {
                let relativePath = String(currentSelected.path.dropFirst(sourceStandardized.path.count))
                selectedFileURL = destStandardized.appendingPathComponent(relativePath)
            }
        }
    }
    
    private func performDelete() {
        guard let item = itemToDelete else { return }
        do {
            try FileManagerService.shared.deleteItem(at: item.url)
            if selectedFileURL?.standardizedFileURL.path == item.url.standardizedFileURL.path ||
                (item.isDirectory && selectedFileURL?.standardizedFileURL.path.hasPrefix(item.url.standardizedFileURL.path + "/") == true) {
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

// MARK: - Move Item Sheet

struct MoveItemSheet: View {
    let item: FileItem
    let currentFolderURL: URL
    let onMove: (URL) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var availableFolders: [FolderItemInfo] = []
    @State private var selectedDestinationURL: URL? = nil
    
    // New folder inside sheet
    @State private var showNewFolderDialog: Bool = false
    @State private var newFolderName: String = ""
    @State private var alertErrorMessage: String? = nil
    @State private var showAlertError: Bool = false
    
    private var isCurrentLocation: Bool {
        guard let selected = selectedDestinationURL else { return false }
        return selected.standardizedFileURL.path == currentFolderURL.standardizedFileURL.path
    }
    
    private var currentLocationName: String {
        if currentFolderURL.standardizedFileURL.path == FileManagerService.shared.documentsDirectory.standardizedFileURL.path {
            return "Mini C (Root)"
        }
        return currentFolderURL.lastPathComponent
    }
    
    private var moveButtonTitle: String {
        guard let selected = selectedDestinationURL else {
            return "Select Destination"
        }
        if isCurrentLocation {
            return "Already in this folder"
        }
        let folderName = selected.standardizedFileURL.path == FileManagerService.shared.documentsDirectory.standardizedFileURL.path ? "Mini C" : selected.lastPathComponent
        return "Move to '\(folderName)'"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with item info
                HStack(spacing: 12) {
                    if item.isDirectory {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    } else if let type = item.fileType {
                        Image(systemName: type.systemIcon)
                            .font(.title2)
                            .foregroundStyle(type.badgeColor)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.title2)
                            .foregroundStyle(.gray)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.headline)
                        
                        Text("Current location: \(currentLocationName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                
                // Destination Folders List
                List {
                    Section {
                        ForEach(availableFolders) { folder in
                            let isCurrent = folder.url.standardizedFileURL.path == currentFolderURL.standardizedFileURL.path
                            let isInvalid = isInvalidFolder(folder.url)
                            let isSelected = selectedDestinationURL?.standardizedFileURL.path == folder.url.standardizedFileURL.path
                            
                            Button {
                                if !isCurrent && !isInvalid {
                                    selectedDestinationURL = folder.url
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if folder.depth > 0 {
                                        Spacer()
                                            .frame(width: CGFloat(folder.depth * 18))
                                    }
                                    
                                    Image(systemName: folder.isRoot ? "externaldrive.fill" : "folder.fill")
                                        .foregroundStyle(folder.isRoot ? .indigo : .blue)
                                        .font(.body)
                                    
                                    Text(folder.name)
                                        .foregroundStyle(isInvalid ? .secondary : .primary)
                                        .fontWeight(folder.isRoot ? .semibold : .regular)
                                    
                                    Spacer()
                                    
                                    if isCurrent {
                                        Text("Current")
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                    } else if isInvalid {
                                        Text("Invalid")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                            .fontWeight(.semibold)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isCurrent || isInvalid)
                        }
                    } header: {
                        Text("Select Destination Folder")
                    } footer: {
                        Text("Select where you want to move '\(item.name)'.")
                    }
                }
                
                // Bottom Move Action Bar
                VStack(spacing: 8) {
                    Button {
                        if let selected = selectedDestinationURL {
                            onMove(selected)
                        }
                    } label: {
                        Text(moveButtonTitle)
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDestinationURL == nil || isCurrentLocation)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
            }
            .navigationTitle("Move Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderName = ""
                        showNewFolderDialog = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .alert("New Folder", isPresented: $showNewFolderDialog) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    createNewFolder()
                }
            } message: {
                Text("Create a new folder in '\(activeTargetFolderForNewFolder.standardizedFileURL.path == FileManagerService.shared.documentsDirectory.standardizedFileURL.path ? "Mini C" : activeTargetFolderForNewFolder.lastPathComponent)'.")
            }
            .alert("Error", isPresented: $showAlertError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertErrorMessage ?? "An unknown error occurred.")
            }
            .onAppear {
                reloadFolders()
            }
        }
    }
    
    private var activeTargetFolderForNewFolder: URL {
        if let selected = selectedDestinationURL, !isInvalidFolder(selected) {
            return selected
        }
        return currentFolderURL
    }
    
    private func isInvalidFolder(_ url: URL) -> Bool {
        guard item.isDirectory else { return false }
        let targetPath = url.standardizedFileURL.path
        let itemPath = item.url.standardizedFileURL.path
        return targetPath == itemPath || targetPath.hasPrefix(itemPath + "/")
    }
    
    private func reloadFolders() {
        availableFolders = FileManagerService.shared.allFolders()
        // Pre-select parent folder or root if moving out
        if selectedDestinationURL == nil {
            if currentFolderURL.standardizedFileURL.path != FileManagerService.shared.documentsDirectory.standardizedFileURL.path {
                selectedDestinationURL = currentFolderURL.deletingLastPathComponent()
            }
        }
    }
    
    private func createNewFolder() {
        do {
            let newURL = try FileManagerService.shared.createFolder(name: newFolderName, in: activeTargetFolderForNewFolder)
            reloadFolders()
            selectedDestinationURL = newURL
        } catch {
            alertErrorMessage = error.localizedDescription
            showAlertError = true
        }
    }
}

#Preview {
    ContentView()
}
