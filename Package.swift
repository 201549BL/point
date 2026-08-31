// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Point",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Point", targets: ["Point"]),
    ],
    targets: [
        .executableTarget(
            name: "Point",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(name: "PointTests", dependencies: ["Point"]),
    ]
)
