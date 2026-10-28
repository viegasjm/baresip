// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BaresipMac", platforms: [.macOS(.v14)], products: [.executable(name: "BaresipMac", targets: ["BaresipMac"])], targets: [.executableTarget(name: "BaresipMac")])
