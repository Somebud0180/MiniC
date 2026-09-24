import Foundation
import SwiftUI

enum FileType: String, CaseIterable, Identifiable, Codable {
    case c
    case cpp
    
    var id: Self { self }
    
    var displayName: String {
        switch self {
        case .c: return "C Program"
        case .cpp: return "C++ Program"
        }
    }
    
    var extensionName: String {
        switch self {
        case .c: return "c"
        case .cpp: return "cpp"
        }
    }
    
    var systemIcon: String {
        switch self {
        case .c: return "doc.text.fill"
        case .cpp: return "doc.badge.gearshape.fill"
        }
    }
    
    var badgeColor: Color {
        switch self {
        case .c: return .blue
        case .cpp: return .purple
        }
    }
    
    var defaultTemplate: String {
        switch self {
        case .c:
            return """
            #include <stdio.h>

            int main() {
                printf("Hello, World!\\n");
                return 0;
            }
            """
        case .cpp:
            return """
            #include <iostream>

            int main() {
                std::cout << "Hello, World!" << std::endl;
                return 0;
            }
            """
        }
    }
    
    static func detect(from url: URL) -> FileType? {
        let ext = url.pathExtension.lowercased()
        if ext == "c" {
            return .c
        } else if ext == "cpp" || ext == "cc" || ext == "cxx" || ext == "hpp" || ext == "h" {
            return .cpp
        }
        return nil
    }
}

struct FileItem: Identifiable, Hashable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileType: FileType?
    let modificationDate: Date?
    let size: Int64
    
    init(url: URL, isDirectory: Bool, modificationDate: Date? = nil, size: Int64 = 0) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.fileType = isDirectory ? nil : FileType.detect(from: url)
        self.modificationDate = modificationDate
        self.size = size
    }
    
    var formattedSize: String {
        if isDirectory {
            return "Folder"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var formattedDate: String {
        guard let date = modificationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
