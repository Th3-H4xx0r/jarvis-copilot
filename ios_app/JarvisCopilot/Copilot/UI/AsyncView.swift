import SwiftUI

/// Owns the loading / error / empty / pull-to-refresh boilerplate every data
/// screen needs, so a screen only says how to load and how to render. Ported from
/// `widgets/async_view.dart`.
///
/// ```swift
/// AsyncView(emptyText: "No todos yet.", isEmpty: \.isEmpty) {
///     try await TodosAPI().list()
/// } content: { todos, reload in
///     List(todos) { … }
/// }
/// ```
///
/// The `reload` closure handed to `content` is the imperative refresh Flutter
/// exposes as `AsyncViewController.refresh()` — call it after a mutation.
struct AsyncView<Value, Content: View>: View {
    let load: () async throws -> Value
    var isEmpty: (Value) -> Bool = { _ in false }
    var emptyText: String = "Nothing here yet."
    @ViewBuilder let content: (Value, @escaping () -> Void) -> Content

    init(emptyText: String = "Nothing here yet.",
         isEmpty: @escaping (Value) -> Bool = { _ in false },
         load: @escaping () async throws -> Value,
         @ViewBuilder content: @escaping (Value, @escaping () -> Void) -> Content) {
        self.load = load
        self.isEmpty = isEmpty
        self.emptyText = emptyText
        self.content = content
    }

    @State private var model = AsyncLoad<Value>()

    var body: some View {
        Group {
            if let value = model.value {
                if isEmpty(value) {
                    ScrollView { CenteredMessage(text: emptyText).padding(.top, 120) }
                } else {
                    content(value, { model.token += 1 })
                }
            } else if let message = model.errorMessage {
                CenteredMessage(text: message, color: JcTheme.danger) { model.token += 1 }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A refresh that failed while a value is still on screen would otherwise
        // be completely invisible — the spinner retracts and nothing changes.
        .loadErrorBanner(model.lastError, hasContent: model.value != nil)
        // `id:` restarts the task on every reload request, and cancels the
        // in-flight one — a screen left mid-load never lands stale data.
        .task(id: model.token) { await model.run(load) }
        .refreshable { await model.run(load) }
    }
}

/// The loading state behind an `AsyncView`. Separate and generic so a store can
/// own one directly when a screen needs more control than the view offers.
@MainActor
@Observable
final class AsyncLoad<Value> {
    private(set) var value: Value?
    /// The full-screen failure — set only when there is nothing to show.
    private(set) var errorMessage: String?
    /// The last failure, whether or not a stale value survived it. This is what
    /// makes a failed refresh visible: `errorMessage` alone left the screen
    /// showing stale data with no hint that the reload never landed.
    private(set) var lastError: String?
    private(set) var isLoading = false
    /// Bumped to request a reload.
    var token = 0

    func run(_ load: () async throws -> Value) async {
        isLoading = true
        errorMessage = nil
        do {
            value = try await load()
            lastError = nil
        } catch is CancellationError {
            // A superseded reload — leave whatever is on screen alone.
        } catch {
            // Keep the last good value so a refresh failure doesn't blank the
            // screen; the full-screen message is only for an empty screen, and
            // `lastError` carries the banner for the rest.
            let message = JcLog.report(JcLog.ui, "async load", error)
            lastError = message
            if value == nil { errorMessage = message }
        }
        isLoading = false
    }
}

/// The centred "nothing here" / "that failed" message, with an optional Retry.
struct CenteredMessage: View {
    let text: String
    var color: Color = JcTheme.muted
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(JcText.body)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(JcText.label)
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
