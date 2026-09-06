// swift-tools-version: 5.9
// Kyutai's Moshi (speech-to-speech) and Mimi (audio codec) on MLX, vendored from
// https://github.com/kyutai-labs/moshi-swift (MIT, see LICENSE.kyutai) as its own
// module so the app imports `MoshiLib` and nothing else. `MoshiRuntime.swift` is
// ours: it wraps model download/load and the per-frame step loop.
import PackageDescription

let package = Package(
    name: "MoshiLib",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MoshiLib", targets: ["MoshiLib"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.21.2"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.15"),
    ],
    targets: [
        .target(
            name: "MoshiLib",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),   // Hub + Tokenizers modules
            ]),
        .testTarget(name: "MoshiLibTests", dependencies: ["MoshiLib"]),
    ]
)
