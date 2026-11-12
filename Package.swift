// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickMD",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "QuickMD", targets: ["QuickMD"])
    ],
    targets: [
        .executableTarget(
            name: "QuickMD",
            path: "QuickMD/QuickMD",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "QuickMD.entitlements",
                "Resources",
                "TipJarProducts.storekit",
                "en.lproj",
                "zh-Hans.lproj"
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)