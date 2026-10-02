#!/usr/bin/env swift
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let package = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent(".build/SourcePackages/checkouts/miniclang")
let bootstrap = package.appendingPathComponent("Tools/bootstrap-offline-clang.swift")
guard FileManager.default.fileExists(atPath: bootstrap.path) else {
    fputs("MiniClang checkout missing at \(package.path). Resolve packages first, or pass the checkout path as an argument.\n", stderr)
    exit(1)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", bootstrap.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
