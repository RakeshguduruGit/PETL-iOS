// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PETL",
    platforms: [
        .iOS(.v16)
    ],
    dependencies: [
        .package(url: "https://github.com/OneSignal/OneSignal-iOS-SDK", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "PETL",
            dependencies: ["OneSignalFramework"]
        )
    ]
) 