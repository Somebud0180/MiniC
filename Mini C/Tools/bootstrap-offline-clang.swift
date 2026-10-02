#!/usr/bin/env swift
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let package = root.deletingLastPathComponent().appendingPathComponent("MiniClang")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", package.appendingPathComponent("Tools/bootstrap-offline-clang.swift").path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
