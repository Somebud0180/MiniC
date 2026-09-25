//
//  SettingsView.swift
//  Mini C
//
//  Created by Ethan John Lagera on 9/25/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = EditorSettings.shared
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Image("Icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                        
                        Text("Mini C")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Manage your settings here. Modify how the smart code structuring works, set auto-save and more.")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Smart Code Structuring") {
                    Toggle(isOn: $settings.autoIndent) {
                        Label("Auto-Indent", systemImage: "arrow.right.to.line.compact")
                    }
                    
                    Toggle(isOn: $settings.autoBrackets) {
                        Label("Auto-Close Brackets & Quotes", systemImage: "curlybraces")
                    }
                    
                    Toggle(isOn: $settings.autoDeletePairs) {
                        Label("Auto-Delete Matching Pairs", systemImage: "delete.left")
                    }
                    
                    Toggle(isOn: $settings.autoDedent) {
                        Label("Auto-Dedent Closing Brace", systemImage: "arrow.left.to.line.compact")
                    }
                    
                    Toggle(isOn: $settings.wrapSelection) {
                        Label("Wrap Selection with Brackets", systemImage: "rectangle.and.hand.point.up.left")
                    }
                }
                
                Section("Indentation") {
                    Picker("Indent Style", selection: $settings.indentWithSpaces) {
                        Text("Spaces").tag(true)
                        Text("Tabs").tag(false)
                    }
                    
                    if settings.indentWithSpaces {
                        Picker("Indent Width", selection: $settings.indentWidth) {
                            Text("2 spaces").tag(2)
                            Text("4 spaces").tag(4)
                            Text("8 spaces").tag(8)
                        }
                    }
                }
                
                Section("Prettify (Code Formatting)") {
                    Toggle(isOn: $settings.trimTrailingWhitespace) {
                        Label("Trim Trailing Whitespace", systemImage: "scissors")
                    }
                    
                    Toggle(isOn: $settings.formatOnSave) {
                        Label("Format on Save", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                }
                
                Section {
                    Toggle(isOn: $settings.autoSave) {
                        Label("Auto-Save Changes", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("Saving")
                } footer: {
                    Text("Automatically saves code 1.5 seconds after editing.")
                }
                
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        resetDefaults()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func resetDefaults() {
        settings.autoIndent = true
        settings.autoBrackets = true
        settings.autoDeletePairs = true
        settings.indentWithSpaces = false
        settings.indentWidth = 4
        settings.wrapSelection = true
        settings.autoDedent = true
        settings.trimTrailingWhitespace = true
        settings.autoSave = true
        settings.formatOnSave = false
    }
}

#Preview {
    SettingsView()
}
