import XCTest
@testable import OnDeviceLLM

final class OnDeviceLLMTests: XCTestCase {
    func testStorageLayoutMatchesTheHubSnapshotPath() {
        // Download, install-check and delete must all look at the Hub layout.
        let dir = LocalLLM.directory(for: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertTrue(dir.path.hasSuffix("OnDeviceModels/models/mlx-community/Qwen2.5-0.5B-Instruct-4bit"), dir.path)
        XCTAssertFalse(LocalLLM.isInstalled("mlx-community/does-not-exist"))
    }

    func testInstalledMeansWeightsPresent() throws {
        let id = "test-org/test-model-\(UUID().uuidString)"
        let dir = LocalLLM.directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? LocalLLM.delete(id) }
        try "{}".write(to: dir.appending(path: "config.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LocalLLM.isInstalled(id), "config alone is a half-finished download")
        try Data([0, 1]).write(to: dir.appending(path: "model.safetensors"))
        XCTAssertTrue(LocalLLM.isInstalled(id))
        XCTAssertEqual(LocalLLM.installedSizeBytes(id), 4)
        try LocalLLM.delete(id)
        XCTAssertFalse(LocalLLM.isInstalled(id))
    }
}
