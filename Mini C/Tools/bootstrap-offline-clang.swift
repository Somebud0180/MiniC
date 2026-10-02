#!/usr/bin/env swift
// Build-time downloader only. The installed app never downloads a compiler or SDK.
import Foundation
import CryptoKit

let revision = "dfc989da6e3c0617c89c5f14a44e832cf8568b8d"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let prototype = root.appendingPathComponent("Mini C/OfflineClang")
let vendor = prototype.appendingPathComponent("Vendor")
let downloads = prototype.appendingPathComponent(".downloads")
let fm = FileManager.default
try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
func download(_ url: URL) throws -> Data {
    let wait = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>!
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 120
    let session = URLSession(configuration: config)
    session.dataTask(with: url) { data, response, error in
        defer { wait.signal() }
        if let error { result = .failure(error) }
        else if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result = .success(data) }
        else { result = .failure(NSError(domain: "OfflineClangDownload", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Download failed: \(url)"])) }
    }.resume()
    wait.wait()
    return try result.get()
}
func command(_ tool: String, _ args: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = args
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "Bootstrap", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"]) }
}
let assets: [(String, String, String)] = [
    ("clang.xcframework.zip", "https://github.com/holzschu/llvm-project/releases/download/14.0.0/clang.xcframework.zip", "9de9f72334c99f27d3ac5844b8d3feffcaed3086997e7c2538f887667e8ca179"),
    ("libLLVM.xcframework.zip", "https://github.com/holzschu/llvm-project/releases/download/14.0.0/libLLVM.xcframework.zip", "bbae5b3a7952b2f1e89fb93b25b41931a53b6d8c99d24dfe6a893e615b177428"),
    ("lld.xcframework.zip", "https://github.com/holzschu/llvm-project/releases/download/14.0.0/lld.xcframework.zip", "240c1cd5cfc7557dd859af9b9d20aa9623f935dc92746a8be21edba8dbd11f34"),
    ("ios_system.xcframework.zip", "https://github.com/holzschu/ios_system/releases/download/v3.0.5/ios_system.xcframework.zip", "d429e68102926f58bedd8e8b7105dcd169478cd6da1cef494a5f468482d1c8f5"),
    ("llvm.tar.gz", "https://github.com/holzschu/a-Shell-commands/releases/download/0.1/llvm.tar.gz", "9093f50cc55c0977f89f6761e47b6ed932b0dee18127c5230e253acee52ae470")
]
for (name, url, expected) in assets {
    let archive = downloads.appendingPathComponent(name)
    let data = fm.fileExists(atPath: archive.path) ? try Data(contentsOf: archive) : try download(URL(string: url)!)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard hash == expected else { fatalError("Checksum mismatch for \(name): \(hash)") }
    try data.write(to: archive)
    if name.hasSuffix(".zip") { try command("/usr/bin/ditto", ["-x", "-k", archive.path, vendor.path]) }
    else { try command("/usr/bin/tar", ["-xzf", archive.path, "-C", vendor.path]) }
    print("Verified and extracted \(name)")
}
let runtime = vendor.appendingPathComponent("WasmKit")
let treeData = try download(URL(string: "https://api.github.com/repos/swiftwasm/WasmKit/git/trees/\(revision)?recursive=1")!)
let tree = try JSONSerialization.jsonObject(with: treeData) as! [String: Any]
let entries = tree["tree"] as! [[String: Any]]
let prefixes = ["Sources/WasmKit/", "Sources/WasmParser/", "Sources/WasmTypes/", "Sources/_CWasmKit/", "Sources/WASI/", "Sources/WasmKitWASI/"]
for entry in entries {
    let path = entry["path"] as! String
    guard entry["type"] as? String == "blob", prefixes.contains(where: path.hasPrefix) || path == "LICENSE" else { continue }
    guard !path.split(separator: "/").contains("..") else { fatalError("Unsafe upstream path") }
    let target = runtime.appendingPathComponent(path)
    let data = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : try download(URL(string: "https://raw.githubusercontent.com/swiftwasm/WasmKit/\(revision)/\(path)")!)
    var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
    let hash = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    guard hash == entry["sha"] as? String else { fatalError("Runtime source hash mismatch: \(path)") }
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: target)
}
try fm.copyItemReplacing(at: prototype.appendingPathComponent("WasmKit.Package.swift.template"), to: runtime.appendingPathComponent("Package.swift"))
try revision.write(to: runtime.appendingPathComponent("UPSTREAM_REVISION"), atomically: true, encoding: .utf8)
// Xcode's build-script sandbox requires every directory and file used by rsync.
var inputs: [String] = []
for name in ["usr", "clang.xcframework", "lld.xcframework", "libLLVM.xcframework", "ios_system.xcframework"] {
    let directory = vendor.appendingPathComponent(name)
    inputs.append("$(SRCROOT)/Mini C/OfflineClang/Vendor/" + name)
    if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
        for case let file as URL in enumerator {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            inputs.append("$(SRCROOT)/" + relative)
        }
    }
}
let licenses = prototype.appendingPathComponent("Licenses")
inputs.append("$(SRCROOT)/Mini C/OfflineClang/Licenses")
if let enumerator = fm.enumerator(at: licenses, includingPropertiesForKeys: nil) {
    for case let file as URL in enumerator { inputs.append("$(SRCROOT)/" + String(file.path.dropFirst(root.path.count + 1))) }
}
let fixtures = prototype.appendingPathComponent("Tests/OfflineClangCoreTests/Fixtures")
inputs.append("$(SRCROOT)/Mini C/OfflineClang/Tests/OfflineClangCoreTests/Fixtures")
if let enumerator = fm.enumerator(at: fixtures, includingPropertiesForKeys: nil) {
    for case let file as URL in enumerator { inputs.append("$(SRCROOT)/" + String(file.path.dropFirst(root.path.count + 1))) }
}
try (inputs.sorted().joined(separator: "\n") + "\n").write(to: vendor.appendingPathComponent("inputs.xcfilelist"), atomically: true, encoding: .utf8)
print("WasmKit sources verified at \(revision). Ready for an offline iPhone build.")
print("Optional host verification: install desktop wasi-sdk 14.0 and set MINIC_WASI_SDK / MINIC_SYSROOT as documented.")

extension FileManager {
    func copyItemReplacing(at source: URL, to target: URL) throws {
        if fileExists(atPath: target.path) { try removeItem(at: target) }
        try copyItem(at: source, to: target)
    }
}
