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
                "CadovaLiveLinkCore",
                "CadovaLiveLinkServer",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Deliberately not a dependency on the Cadova package — Cadova Viewer never needs the rest
        // of Cadova (Manifold/C++, geometry engine), just the LiveLink wire format and listener, so
        // these are a local, unshared copy rather than a cross-package dependency. See LiveLinkMessage
        // and LiveLinkFraming in Cadova's own CadovaLiveLinkCore for the sending side's matching copy
        // — keep the two in sync by hand if the wire format ever changes.
        .target(name: "CadovaLiveLinkCore"),
        .target(
            name: "CadovaLiveLinkServer",
            dependencies: ["CadovaLiveLinkCore"]
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
                "CadovaLiveLinkCore",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
