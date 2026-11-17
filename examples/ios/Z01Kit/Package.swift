// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Z01Kit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Z01Kit", targets: ["Z01Kit"])],
    targets: [
        .target(name: "Z01Kit"),
        .testTarget(name: "Z01KitTests", dependencies: ["Z01Kit"]),
    ]
)
