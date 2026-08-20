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
        .package(url: "https://github.com/tomasf/Nodal", .upToNextMajor(from: "1.0.2")),
        .package(url: "https://github.com/tomasf/Zip.git", from: "2.1.0"),
        .package(url: "https://github.com/tomasf/manifold-swift.git", .upToNextMajor(from: "1.1.0")),
        .package(url: "https://github.com/tomasf/CadovaLiveLink.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ViewerCore",
            dependencies: [
                .product(name: "ThreeMF", package: "ThreeMF"),
                .product(name: "Nodal", package: "Nodal"),
                .product(name: "Zip", package: "Zip"),
                .product(name: "Manifold", package: "manifold-swift"),
                // Cadova Viewer never needs the rest of Cadova (Manifold/C++, geometry engine) —
                // just the LiveLink wire format and listener, shared with Cadova itself via this
                // package. CadovaLiveLinkCore isn't its own product, but is visible transitively
                // through CadovaLiveLinkHost.
                .product(name: "CadovaLiveLinkHost", package: "CadovaLiveLink"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .executableTarget(
            name: "cadova-render",
            dependencies: [
                "ViewerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "ViewerCoreTests",
            dependencies: [
                "ViewerCore",
                .product(name: "ThreeMF", package: "ThreeMF"),
                .product(name: "Manifold", package: "manifold-swift"),
                .product(name: "CadovaLiveLinkHost", package: "CadovaLiveLink"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
