// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "soapcap-session-app",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Soapcap", path: "Sources/Soapcap")
    ]
)
