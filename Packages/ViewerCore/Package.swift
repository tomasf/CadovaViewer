// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ViewerCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ViewerCore", targets: ["ViewerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tomasf/ThreeMF", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/tomasf/Nodal", .upToNextMajor(from: "0.3.3")),
    ],
    targets: [
        .target(
            name: "ViewerCore",
            dependencies: [
                .product(name: "ThreeMF", package: "ThreeMF"),
                .product(name: "Nodal", package: "Nodal"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
