import SwiftUI

enum FileType: String, CaseIterable, Identifiable {
    case c, cpp
    
    var id: Self { self }
    
    var name: String {
        switch self {
        case .c: return "C"
        case .cpp: return "C++"
        }
    }
}

struct ContentView: View {
    @State var presentFileCreationDialog: Bool = false
    @State var fileCreationName: String = ""
    @State var fileCreationType: FileType = .c
    
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    Text("Code.c")
                } label: {
                    Text("Code.c")
                }
            }
            .navigationTitle("Mini C")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: {
                        presentFileCreationDialog = true
                    }, label: {
                        Image(systemName: "plus")
                    })
                    
                    Button(action: {
                        // Open Settings
                    }, label: {
                        Image(systemName: "gear")
                    })
                }
            }
            .sheet(isPresented: $presentFileCreationDialog, onDismiss: {
                fileCreationName = ""
                fileCreationType = .c
            }) {
                NavigationStack {
                    Form {
                        VStack(alignment: .leading) {
                            Text("File name")
                                .font(.caption)
                            TextField("Program", text: $fileCreationName)
                        }
                        
                        Picker("File type", selection: $fileCreationType) {
                            ForEach(FileType.allCases) { fileType in
                                Text(fileType.name).tag(fileType.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        Button(action: {
                            // Save and open new file
                        }, label: {
                            Text("Save")
                                .padding(8)
                                .frame(maxWidth: .infinity)
                        })
                        .tint(.blue)
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, -16)
                    .navigationTitle("Create New File")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: {
                                presentFileCreationDialog = false
                            }, label: {
                                Label("Cancel", systemImage: "xmark")
                            })
                        }
                    }
                }
                .presentationDetents([.fraction(0.42)])
            }
        }
    }
}

#Preview {
    ContentView()
}
