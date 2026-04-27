// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pointer",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Pointer",
            path: "Sources/Pointer",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Pointer/Info.plist",
                ])
            ]
        )
    ]
)
