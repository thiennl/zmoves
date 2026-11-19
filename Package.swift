// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zmove",
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "ZMove",
            dependencies: ["CSQLite"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
         .executableTarget(
             name: "zmove",
             dependencies: ["ZMove"],
             swiftSettings: [.swiftLanguageMode(.v5)]
         ),
         .executableTarget(
             name: "zmmboxmove",
             dependencies: ["ZMove"],
             swiftSettings: [.swiftLanguageMode(.v5)]
         ),
        .testTarget(
            name: "ZMoveTests",
            dependencies: ["ZMove"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
