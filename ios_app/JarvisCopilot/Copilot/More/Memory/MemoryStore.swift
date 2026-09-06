import Foundation
import Observation

/// Page state for the Memory screen: the two files, the selected section, and
/// the save round-trip for the editor sheet.
@Observable
@MainActor
final class MemoryStore {
    private let api: MemoryAPI
    private let task = TaskHandle()

    private(set) var documents = MemoryDocuments()
    var section: MemorySection = .memory
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    init(api: MemoryAPI = MemoryAPI()) { self.api = api }

    deinit { task.cancel() }

    var content: String { documents.content(for: section) }
    var mtimeLabel: String { documents.mtimeLabel(for: section) }
    var path: String? { documents.path(for: section) }
    /// The Edit button stays disabled until something has actually loaded.
    var canEdit: Bool { hasLoaded && !documents.isEmpty }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in
            await self?.refresh()
        })
    }

    func refresh() async {
        do {
            let docs = try await api.read()
            documents = docs
            isLoading = false
            hasLoaded = true
            errorMessage = nil
        } catch {
            isLoading = false
            hasLoaded = true
            errorMessage = apiErrorMessage(error)
        }
    }

    /// Save the current section, then re-read so the mtime chip updates.
    /// Returns false (with `errorMessage` set) when the write failed.
    @discardableResult
    func save(_ text: String) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await api.write(section, content: text)
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
        await refresh()
        return true
    }
}
