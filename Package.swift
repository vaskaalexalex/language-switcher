// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LanguageSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LanguageSwitcher", targets: ["LanguageSwitcher"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LanguageSwitcher",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/LanguageSwitcher"
        ),
        .testTarget(
            name: "LanguageSwitcherTests",
            dependencies: ["LanguageSwitcher"],
            path: "Tests/LanguageSwitcherTests"
        )
    ]
)
