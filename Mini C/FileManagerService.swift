import Foundation
import SwiftUI

@Observable
final class FileManagerService {
    static let shared = FileManagerService()
    
    let fileManager = FileManager.default
    
    /// The root accessible Documents directory for the app.
    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    init() {
        createInitialSampleFilesIfNeeded()
    }
    
    /// Fetches all items (folders, .c, .cpp files) inside the given directory URL.
    func contentsOfDirectory(at url: URL) -> [FileItem] {
        do {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey]
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
            
            var items: [FileItem] = []
            
            for itemURL in contents {
                let resourceValues = try itemURL.resourceValues(forKeys: Set(resourceKeys))
                let isDirectory = resourceValues.isDirectory ?? false
                let modDate = resourceValues.contentModificationDate
                let fileSize = Int64(resourceValues.fileSize ?? 0)
                
                // Keep directories and supported C/C++ files
                if isDirectory {
                    items.append(FileItem(url: itemURL, isDirectory: true, modificationDate: modDate, size: fileSize))
                } else if FileType.detect(from: itemURL) != nil {
                    items.append(FileItem(url: itemURL, isDirectory: false, modificationDate: modDate, size: fileSize))
                }
            }
            
            // Sort folders first, then files alphabetically
            return items.sorted { first, second in
                if first.isDirectory != second.isDirectory {
                    return first.isDirectory && !second.isDirectory
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
        } catch {
            print("Error listing contents of directory \(url.path): \(error.localizedDescription)")
            return []
        }
    }
    
    /// Creates a new C or C++ file inside the specified folder directory.
    @discardableResult
    func createFile(name: String, type: FileType, in folderURL: URL, content: String? = nil) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var fileName = trimmedName.isEmpty ? "main" : trimmedName
        
        let expectedExtension = ".\(type.extensionName)"
        if !fileName.lowercased().hasSuffix(expectedExtension) {
            fileName += expectedExtension
        }
        
        let targetURL = folderURL.appendingPathComponent(fileName)
        
        if fileManager.fileExists(atPath: targetURL.path) {
            throw NSError(domain: "FileManagerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "A file with name '\(fileName)' already exists."])
        }
        
        let initialContent = content ?? type.defaultTemplate
        try initialContent.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }
    
    /// Creates a new subdirectory in the specified folder directory.
    @discardableResult
    func createFolder(name: String, in folderURL: URL) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = trimmedName.isEmpty ? "New Folder" : trimmedName
        let targetURL = folderURL.appendingPathComponent(folderName)
        
        if fileManager.fileExists(atPath: targetURL.path) {
            throw NSError(domain: "FileManagerService", code: 2, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(folderName)' already exists."])
        }
        
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
        return targetURL
    }
    
    /// Reads file string content from given file URL.
    func readFileContent(at url: URL) throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    /// Writes content to given file URL.
    func saveFileContent(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    /// Renames a file or folder.
    @discardableResult
    func renameItem(at url: URL, to newName: String) throws -> URL {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "FileManagerService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."])
        }
        
        let parentURL = url.deletingLastPathComponent()
        var finalName = trimmedName
        
        // Retain extension if file and missing extension
        if !url.hasDirectoryPath {
            let originalExt = url.pathExtension
            if !originalExt.isEmpty && !finalName.lowercased().hasSuffix(".\(originalExt.lowercased())") {
                finalName += ".\(originalExt)"
            }
        }
        
        let destinationURL = parentURL.appendingPathComponent(finalName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw NSError(domain: "FileManagerService", code: 4, userInfo: [NSLocalizedDescriptionKey: "An item named '\(finalName)' already exists."])
        }
        
        try fileManager.moveItem(at: url, to: destinationURL)
        return destinationURL
    }
    
    /// Deletes a file or folder item.
    func deleteItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
    
    /// Duplicates a file or folder item.
    @discardableResult
    func duplicateItem(at url: URL) throws -> URL {
        let parentURL = url.deletingLastPathComponent()
        let nameWithoutExt = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        
        var counter = 1
        var newName = "\(nameWithoutExt) copy" + (ext.isEmpty ? "" : ".\(ext)")
        var destinationURL = parentURL.appendingPathComponent(newName)
        
        while fileManager.fileExists(atPath: destinationURL.path) {
            counter += 1
            newName = "\(nameWithoutExt) copy \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            destinationURL = parentURL.appendingPathComponent(newName)
        }
        
        try fileManager.copyItem(at: url, to: destinationURL)
        return destinationURL
    }
    
    /// Creates default sample starter files on first application launch if documents directory is empty.
    private func createInitialSampleFilesIfNeeded() {
        let root = documentsDirectory
        let existingContents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        
        if existingContents.isEmpty {
            let sampleC = """
            #include <stdio.h>

            int main() {
                printf("Welcome to Mini C!\\n");
                return 0;
            }
            """
            
            let sampleCPP = """
            #include <iostream>

            int main() {
                std::cout << "Hello from C++ in Mini C!" << std::endl;
                return 0;
            }
            """
            
            _ = try? createFile(name: "main", type: .c, in: root, content: sampleC)
            _ = try? createFile(name: "hello", type: .cpp, in: root, content: sampleCPP)
            
            if let samplesDir = try? createFolder(name: "Samples", in: root) {
                let utilsC = """
                #include <stdio.h>

                void greet(const char* name) {
                    printf("Hello, %s!\\n", name);
                }

                int main() {
                    greet("Developer");
                    return 0;
                }
                """
                _ = try? createFile(name: "utils", type: .c, in: samplesDir, content: utilsC)
            }
        }
    }
}
