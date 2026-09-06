import Foundation
import Observation

/// Page state for the Photon setup screen.
///
/// The two secrets are write-only. When one is already stored we show a dotted
/// placeholder and a "saved — leave blank to keep" hint, and on save we only
/// send a secret the user actually typed.
@Observable
@MainActor
final class PhotonStore {
    private let api: PhotonAPI
    private let task = TaskHandle()

    /// Placeholder shown in a secret field that already has a stored value.
    static let secretPlaceholder = "••••••••"

    // Editable form fields.
    var projectID = ""
    var projectSecret = ""
    var notifyTarget = ""
    var sidecarURL = ""
    var sidecarToken = ""
    var allowedUsers = ""
    var allowAll = false

    private(set) var fields: [PhotonField] = []
    private(set) var projectSecretSet = false
    private(set) var sidecarTokenSet = false
    private(set) var configured = false
    private(set) var sidecar = PhotonSidecar()

    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    var toast: String?

    init(api: PhotonAPI = PhotonAPI()) { self.api = api }

    deinit { task.cancel() }

    var status: PhotonStatus {
        PhotonStatus.resolve(configured: configured, sidecar: sidecar)
    }

    /// Hint under a secret field: nil when nothing is stored yet.
    var projectSecretHint: String? {
        projectSecretSet ? "saved — leave blank to keep" : nil
    }

    var sidecarTokenHint: String? {
        sidecarTokenSet ? "saved — leave blank to keep" : nil
    }

    func load() {
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            let config = try await api.config()
            apply(config)
            // Server defaults sidecar_url to http://127.0.0.1:8787; keep
            // whatever it returns so the field is never unexpectedly blank.
            projectID = config.projectID
            notifyTarget = config.notifyTarget
            sidecarURL = config.sidecarURL
            allowedUsers = config.allowedUsers
            allowAll = config.allowAll
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    /// Validate, save, then reflect the post-save state (secret flags flip, the
    /// secret inputs clear, the status pill refreshes from the reloaded gateway).
    @discardableResult
    func save() async -> Bool {
        let id = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = projectSecret           // secrets are sent verbatim
        let token = sidecarToken

        guard !id.isEmpty else {
            errorMessage = "Project ID is required"
            return false
        }
        guard !secret.isEmpty || projectSecretSet else {
            errorMessage = "Project secret is required"
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let config = try await api.save(
                projectID: id,
                projectSecret: secret.isEmpty ? nil : secret,
                notifyTarget: notifyTarget.trimmingCharacters(in: .whitespacesAndNewlines),
                sidecarURL: sidecarURL.trimmingCharacters(in: .whitespacesAndNewlines),
                sidecarToken: token.isEmpty ? nil : token,
                allowedUsers: allowedUsers.trimmingCharacters(in: .whitespacesAndNewlines),
                allowAll: allowAll)
            if !secret.isEmpty { projectSecretSet = true }
            if !token.isEmpty { sidecarTokenSet = true }
            projectSecret = ""
            sidecarToken = ""
            configured = config.configured
            sidecar = config.sidecar
            if !config.fields.isEmpty { fields = config.fields }
            toast = config.configured
                ? "Photon connected — iMessage is set up."
                : "Saved."
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    private func apply(_ config: PhotonConfig) {
        fields = config.fields
        projectSecretSet = config.projectSecretSet
        sidecarTokenSet = config.sidecarTokenSet
        configured = config.configured
        sidecar = config.sidecar
    }
}
