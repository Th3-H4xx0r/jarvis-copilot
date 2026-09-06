import Foundation

/// The Coding tab's write operations: launching sessions, project CRUD, the
/// recovery paths (resume / relaunch on device / reopen terminal) and the
/// per-session actions. Split out of `CodingStore.swift`, which keeps the list,
/// the selection, the poll loops and the approval queue.
///
/// Every one of these follows the same Flutter shape: flip a busy flag, clear
/// `error`, do the call, refresh whatever the server just changed, and turn the
/// failure into one user-facing line.
extension CodingStore {

    // MARK: - Launch

    @discardableResult
    func launch(cwd: String? = nil, repoPath: String? = nil, worktree: Bool = false,
                title: String? = nil, prompt: String? = nil, model: String? = nil,
                host: String = "server", skipPermissions: Bool = false,
                sync: CodingSync? = nil) async -> CodingSession? {
        launching = true
        error = nil
        defer { launching = false }
        do {
            let session = try await api.launch(cwd: cwd, repoPath: repoPath, worktree: worktree,
                                               title: title, prompt: prompt, model: model,
                                               host: host, skipPermissions: skipPermissions,
                                               sync: sync)
            await loadSessions()
            if !session.id.isEmpty { await select(session.id) }
            return session
        } catch {
            self.error = "Could not launch session: \(apiErrorMessage(error))"
            return nil
        }
    }

    /// Launch a new session inside a project (cwd defaults server-side to the
    /// project's repo_path). On success refreshes the tree and opens the session.
    @discardableResult
    func launchInProject(_ projectId: String, cwd: String? = nil, title: String? = nil,
                         prompt: String? = nil, model: String? = nil, host: String? = nil,
                         skipPermissions: Bool = false, sync: CodingSync? = nil) async -> CodingSession? {
        launching = true
        error = nil
        defer { launching = false }
        do {
            let session = try await api.launchInProject(projectId, cwd: cwd, title: title,
                                                        prompt: prompt, model: model, host: host,
                                                        skipPermissions: skipPermissions, sync: sync)
            // Make sure the project is expanded so the new session is visible.
            collapsed.remove(projectId)
            await loadSessions()
            if !session.id.isEmpty { await select(session.id) }
            return session
        } catch {
            self.error = "Could not launch session: \(apiErrorMessage(error))"
            return nil
        }
    }

    // MARK: - Projects

    /// Create a project. Returns its new id (or nil, with `error` set).
    func createProject(name: String, repoPath: String, defaultBranch: String? = nil) async -> String? {
        busyProjects = true
        error = nil
        defer { busyProjects = false }
        do {
            let id = try await api.createProject(name: name, repoPath: repoPath,
                                                 defaultBranch: defaultBranch)
            await loadSessions()
            return id
        } catch {
            self.error = "Could not create project: \(apiErrorMessage(error))"
            return nil
        }
    }

    /// Rename / set sync / branch / ignore rules on a project.
    @discardableResult
    func updateProject(_ id: String, name: String? = nil, defaultBranch: String? = nil,
                       syncEnabled: Bool? = nil, syncDesktopPath: String? = nil,
                       ignoreRules: String? = nil, deviceId: String? = nil) async -> Bool {
        busyProjects = true
        error = nil
        defer { busyProjects = false }
        do {
            try await api.updateProject(id, name: name, defaultBranch: defaultBranch,
                                        syncEnabled: syncEnabled, syncDesktopPath: syncDesktopPath,
                                        ignoreRules: ignoreRules, deviceId: deviceId)
            await loadSessions()
            return true
        } catch {
            self.error = "Could not save project: \(apiErrorMessage(error))"
            return false
        }
    }

    /// Delete a project. `cascade` stops + removes its sessions; otherwise they
    /// become Ungrouped.
    @discardableResult
    func deleteProject(_ id: String, cascade: Bool = false) async -> Bool {
        busyProjects = true
        error = nil
        defer { busyProjects = false }
        do {
            try await api.deleteProject(id, cascade: cascade)
            await loadSessions()
            return true
        } catch {
            self.error = "Could not delete project: \(apiErrorMessage(error))"
            return false
        }
    }

    /// Ask the paired device to re-scan its sessions, then refresh the tree.
    /// Discovery is async over the bridge, so we refresh now and again shortly
    /// after. Best-effort: failures surface as `error` but never throw.
    func discoverRefresh() async {
        busyProjects = true
        do {
            try await api.discoverRefresh()
        } catch {
            self.error = "Rescan request failed: \(apiErrorMessage(error))"
        }
        busyProjects = false
        await loadSessions()
        // Give the device a beat to report back over the bridge, then refresh again.
        rediscoverHandle.replace(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            await self?.loadSessions()
        })
    }

    // MARK: - Recovery (resume / relaunch / reopen)

    /// Resume a discovered-transcript (past) session on its device, then refresh.
    /// Returns the id to open (which may be a NEW one), or nil on failure.
    func resumeSession(_ id: String) async -> String? {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let resumed = try await api.resume(id)
            let openId = (resumed?.id.isEmpty == false) ? resumed!.id : id
            await loadSessions()
            return openId
        } catch {
            self.error = "Could not resume session: \(apiErrorMessage(error))"
            return nil
        }
    }

    /// Relaunch an ENDED session on its DEVICE — a fresh tmux in the same folder,
    /// resuming its transcript. Selects the new live session so its terminal
    /// mounts. Mirrors the WebUI's `codingRelaunchDevice`.
    func relaunchOnDevice() async {
        guard let s = selected else { return }
        let cwd = s.cwd ?? ""
        guard !cwd.isEmpty else {
            error = "Can’t relaunch — this session has no folder. Try “Resume on server”."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let session = try await api.relaunchOnDevice(projectId: s.projectId, cwd: cwd,
                                                          title: s.title,
                                                          resumeSessionId: s.claudeSessionId)
            await loadSessions()
            if let session, !session.id.isEmpty { await select(session.id) }
        } catch {
            self.error = "Relaunch failed: \(apiErrorMessage(error))"
        }
    }

    /// Re-attempt the live-terminal attach for a session whose terminal ended —
    /// re-fetches the detail so a session that's come back to life re-mounts its
    /// terminal; a still-ended one stays on the recovery panel.
    func reopenTerminal() async {
        guard let id = selectedId else { return }
        sessionStores[id]?.detachTerminal()
        await refreshDetail()
    }

    // MARK: - Session actions

    /// Send a message into the session over `/message` (the terminal composer's
    /// path is `CodingSessionStore.sendText`).
    func send(_ text: String) async {
        guard let id = selectedId, !sending else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            let r = await attachments.consume(into: text, sessionId: id)
            if let failure = attachments.error { error = failure }
            guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await api.sendMessage(id, text: r.text)
            await refreshDetail()
        } catch {
            self.error = "Could not send message: \(apiErrorMessage(error))"
        }
    }

    func stop() async {
        guard let id = selectedId, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await api.stop(id)
            await refreshDetail()
            await loadSessions()
        } catch {
            self.error = "Could not stop session: \(apiErrorMessage(error))"
        }
    }

    /// Restart the session (`claude --continue`).
    func restart() async {
        guard let id = selectedId, !busy else { return }
        busy = true
        error = nil
        // Tear the terminal down so it re-attaches to the NEW tmux on next start.
        sessionStores[id]?.detachTerminal()
        defer { busy = false }
        do {
            _ = try await api.restart(id)
            await refreshDetail()
            await loadSessions()
        } catch {
            self.error = "Could not restart session: \(apiErrorMessage(error))"
        }
    }

    /// Stop + permanently remove. On success the selection is cleared and the
    /// list refreshed; returns true so the UI can pop back to the list.
    @discardableResult
    func delete() async -> Bool {
        guard let id = selectedId, !busy else { return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await api.delete(id)
            releaseSessionStore(id)
            clearSelection()
            await loadSessions()
            return true
        } catch {
            self.error = "Could not delete session: \(apiErrorMessage(error))"
            return false
        }
    }

    /// Save per-session settings. Tolerates a 404 (endpoint not deployed yet) with
    /// a friendly note rather than a hard error.
    @discardableResult
    func saveSettings(skipPermissions: Bool? = nil, sync: CodingSync? = nil,
                      cwd: String? = nil) async -> Bool {
        guard let id = selectedId else { return false }
        error = nil
        do {
            try await api.updateSettings(id, skipPermissions: skipPermissions, sync: sync, cwd: cwd)
            await refreshDetail()
            return true
        } catch {
            if case APIError.http(let status, _) = error, status == 404 {
                self.error = "Saving settings isn’t available on this server yet."
            } else {
                self.error = "Could not save settings: \(apiErrorMessage(error))"
            }
            return false
        }
    }
}
