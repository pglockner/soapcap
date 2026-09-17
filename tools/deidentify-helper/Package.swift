// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "soapcap-deidentify-helper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/maziyarpanahi/openmed.git", from: "2.5.0")
    ],
    targets: [
        .executableTarget(
            name: "soapcap-deidentify-helper",
            dependencies: [
                .product(name: "OpenMedKit", package: "openmed")
            ]
        )
    ]
)
