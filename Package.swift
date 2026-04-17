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
    targets: [
        .executableTarget(
            name: "LanguageSwitcher",
            path: "Sources/LanguageSwitcher"
        )
    ]
)
