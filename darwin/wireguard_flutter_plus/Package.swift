// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "wireguard_flutter_plus",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "wireguard-flutter-plus", targets: ["wireguard_flutter_plus"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "wireguard_flutter_plus",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)