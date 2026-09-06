import XCTest
@testable import JarvisCopilot

/// `GET /api/personality/active` → the on-device model, so a locally answered
/// turn sounds like the same assistant. Port of the `setPersona(...)` call
/// `main.dart` made after bootstrapping.
@MainActor
final class PersonaLoaderTests: XCTestCase {

    private func makeLoader() -> (DefaultPersonaLoader, MockTransport, PersonaSink) {
        let (api, transport) = JarvisAPI.mocked()
        let sink = PersonaSink()
        let loader = DefaultPersonaLoader(profiles: ProfilesAPI(api: api)) { sink.applied.append($0) }
        return (loader, transport, sink)
    }

    @MainActor
    final class PersonaSink {
        var applied: [String] = []
    }

    func testTheActivePersonalityIsAppliedToTheOnDeviceModel() async {
        let (loader, transport, sink) = makeLoader()
        transport.enqueue(json: ["prompt": "You are JARVIS. Be terse."])

        await loader.loadPersona()

        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/personality/active")
        XCTAssertEqual(sink.applied, ["You are JARVIS. Be terse."])
    }

    /// No personality configured: keep the built-in one rather than blanking it.
    func testAnEmptyPromptIsNotApplied() async {
        let (loader, transport, sink) = makeLoader()
        transport.enqueue(json: ["prompt": "   "])
        await loader.loadPersona()
        XCTAssertTrue(sink.applied.isEmpty)
    }

    /// Unpaired, offline or an older server: best-effort, the next launch retries.
    func testAFailedFetchChangesNothing() async {
        let (loader, transport, sink) = makeLoader()
        transport.enqueue(json: ["error": "no such endpoint"], status: 404)
        await loader.loadPersona()
        XCTAssertTrue(sink.applied.isEmpty)
    }
}
