// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Paywallex",
    platforms: [.iOS(.v13)],
    products: [.library(name: "Paywallex", targets: ["Paywallex"])],
    targets: [.target(name: "Paywallex", path: "Sources/Paywallex")]
)
