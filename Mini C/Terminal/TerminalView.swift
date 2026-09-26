import SwiftUI

public struct TerminalView: View {
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @ObservedObject public var viewModel: TerminalViewModel
    public var onClose: (() -> Void)? = nil
    
    @State private var isHeaderCollapsed: Bool = false
    @FocusState private var isInputFocused: Bool
    
    public init(viewModel: TerminalViewModel, onClose: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            terminalConsoleBody
                .safeAreaInset(edge: .bottom) {
                    inputBar
                }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isHeaderCollapsed && verticalSizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .onChange(of: isInputFocused) {
            withAnimation(.smooth) {
                isHeaderCollapsed = isInputFocused
            }
        }
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack {
            // Status Badge
            Label(viewModel.status.label, systemImage: viewModel.status.systemIcon)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(viewModel.status.color)
                .background(viewModel.status.color.opacity(0.12), in: Capsule())
            
            if !viewModel.currentFileName.isEmpty {
                Text(viewModel.currentFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 12) {
                if viewModel.isRunning {
                    Button(action: { viewModel.stop() }) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .background(Color.red.opacity(0.12), in: Circle())
                    .help("Stop Execution")
                } else {
                    Button(action: { viewModel.rerun() }) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .background(Color.blue.opacity(0.12), in: Circle())
                    .help("Re-run Program")
                }
                
                Button(action: { viewModel.clear() }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color(uiColor: .secondarySystemFill), in: Circle())
                .help("Clear Terminal")
            }
        }
        .safeAreaPadding(.horizontal)
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .background(Color(uiColor: .secondarySystemBackground))
        .onTapGesture {
            withAnimation(.smooth) {
                isHeaderCollapsed = !isHeaderCollapsed
            }
        }
    }
    
    // MARK: - Terminal Console Body
    
    private var terminalConsoleBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.entries.isEmpty {
                    emptyTerminalPlaceholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(viewModel.entries) { entry in
                            terminalRow(entry)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom_anchor")
                    }
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .onChange(of: viewModel.entries.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.status) {
                if viewModel.status == .waitingForInput {
                    isInputFocused = true
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom_anchor", anchor: .bottom)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func terminalRow(_ entry: TerminalEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            switch entry.style {
            case .system:
                Text(entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .italic()
            case .stdout:
                Text(entry.text)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary)
            case .stderr:
                Text(entry.text)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.red)
            case .stdin:
                Text("❯ \(entry.text)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    
    private var emptyTerminalPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            
            Text("Terminal Ready")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("Run your C or C++ program to see output and provide interactive input.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
    
    // MARK: - Input Bar
    
    private var inputBar: some View {
        HStack(spacing: 8) {
            // Interactive prompt symbol
            Text("❯")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(viewModel.status == .waitingForInput ? .orange : .secondary)
            
            TextField(
                viewModel.status == .waitingForInput ? "Enter input for program..." : "Type input...",
                text: $viewModel.inputText
            )
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .focused($isInputFocused)
            .onSubmit {
                viewModel.sendInput()
            }
            .disabled(!viewModel.isRunning)
            
            if !viewModel.inputText.isEmpty {
                Button(action: {
                    viewModel.sendInput()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(viewModel.status == .waitingForInput ? .orange : .accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(in: Capsule())
        .overlay(
            Capsule()
                .stroke(
                    viewModel.status == .waitingForInput ? Color.orange : Color.clear,
                    lineWidth: 1.5
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
