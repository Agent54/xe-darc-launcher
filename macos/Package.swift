// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "macos",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "macos",
            exclude: [
                "Info.plist",
                "Entitlements.plist",
                "Resources/default-profile",
                "Resources/app.icns",
                "Resources/vms",
                "sandbox"
            ],
            resources: [
                .copy("Resources/Preferences.json"),
                .copy("Resources/sources.json")
            ]
        )
    ]
)
