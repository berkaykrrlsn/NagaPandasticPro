// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NagaPandasticPro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NagaPandasticPro",
            path: "Sources/NagaPandasticPro",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
