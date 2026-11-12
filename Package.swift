// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeTodo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdgeTodoApp", targets: ["EdgeTodoApp"])
    ],
    targets: [
        .executableTarget(
            name: "EdgeTodoApp",
            resources: [.copy("Resources/SiteIcons")]
        ),
        .testTarget(name: "EdgeTodoAppTests", dependencies: ["EdgeTodoApp"])
    ]
)
