// swift-tools-version:6.3
import PackageDescription
// Minimal offline distribution; source pinned by UPSTREAM_REVISION.
let package = Package(name: "WasmKit", platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "WasmKit", targets: ["WasmKit"]), .library(name: "WasmKitWASI", targets: ["WasmKitWASI"]), .library(name: "WASI", targets: ["WASI"])],
    traits: [.default(enabledTraits: ["FileSystem", "MultiThread"]), "FileSystem", "MultiThread"],
    targets: [
        .target(name: "WasmTypes", exclude: ["CMakeLists.txt"]),
        .target(name: "WasmParser", dependencies: ["WasmTypes"], exclude: ["CMakeLists.txt"]),
        .target(name: "_CWasmKit", exclude: ["CMakeLists.txt"]),
        .target(name: "WasmKit", dependencies: ["_CWasmKit", "WasmParser", "WasmTypes"], exclude: ["CMakeLists.txt"], swiftSettings: [.enableExperimentalFeature("RawLayout")]),
        .target(name: "WASI", dependencies: ["WasmTypes"], exclude: ["CMakeLists.txt"]),
        .target(name: "WasmKitWASI", dependencies: ["WasmKit", "WASI"], exclude: ["CMakeLists.txt"])
    ])
