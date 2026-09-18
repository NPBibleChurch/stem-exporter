// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StemExporter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StemExporter", targets: ["StemExporter"]),
        .library(name: "StemExporterKit", targets: ["StemExporterKit"]),
    ],
    targets: [
        .target(
            name: "StemExporterKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "StemExporter",
            dependencies: ["StemExporterKit"],
            resources: [.copy("Resources/AppIcon.icns")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StemExporterKitTests",
            dependencies: ["StemExporterKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
