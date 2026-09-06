// swift-tools-version: 5.9
// On-device chat LLMs (Qwen / Llama, 4-bit) on MLX, via Apple's mlx-swift LLM
// library. Pinned to the mlx-swift-examples release that runs on mlx-swift
// 0.21.2 — the same MLX the MoshiLib package ships — so both resolve to one MLX.
import PackageDescription

let package = Package(
    name: "OnDeviceLLM",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OnDeviceLLM", targets: ["OnDeviceLLM"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.21.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.21.2"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.15"),
    ],
    targets: [
        .target(
            name: "OnDeviceLLM",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]),
        .testTarget(name: "OnDeviceLLMTests", dependencies: ["OnDeviceLLM"]),
    ]
)
