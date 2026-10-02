// swift-tools-version:6.3
import PackageDescription
let package = Package(name: "OfflineClang", platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "OfflineClangCore", targets: ["OfflineClangCore"]), .executable(name: "offline-clang", targets: ["OfflineClangCLI"])],
    dependencies: [.package(path: "Vendor/WasmKit")],
    targets: [
        .target(name: "CompilerBridge", publicHeadersPath: "include"),
        .target(name: "OfflineClangCore", dependencies: ["CompilerBridge", .product(name: "WasmKit", package: "WasmKit"), .product(name: "WasmKitWASI", package: "WasmKit"), .product(name: "WASI", package: "WasmKit")]),
        .executableTarget(name: "OfflineClangCLI", dependencies: ["OfflineClangCore"]),
        .testTarget(name: "OfflineClangCoreTests", dependencies: ["OfflineClangCore"], resources: [.copy("Fixtures")])
    ], swiftLanguageModes: [.v5])
