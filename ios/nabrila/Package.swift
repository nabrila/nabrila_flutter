// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "nabrila",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "nabrila", targets: ["nabrila"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "nabrila",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
