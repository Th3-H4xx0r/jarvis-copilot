import SwiftUI

/// The week with the coding agents (after coucou's weekly recap): time with
/// overlapping turns counted once, what got changed, what you approved, and
/// the highlights. Opened from the Agents toolbar or Monday's notification;
/// shares as a 1080×1920 image.
struct AgentsRecapView: View {
    let api: AgentsAPI
    @Environment(\.dismiss) private var dismiss
    @State private var recap: AgentRecap?
    @State private var error: String?
    @State private var shareImage: Image?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let recap {
                        if recap.isEmpty {
                            empty
                        } else {
                            AgentRecapCard(recap: recap, compact: true)
                        }
                    } else if let error {
                        Text(error).font(JcText.body).foregroundStyle(JcTheme.muted)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ProgressView().tint(JcTheme.accent).padding(.top, 80)
                    }
                }
                .padding(16)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Your week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("My week with the agents", image: shareImage)) {
                            JcIcon("square.and.arrow.up", size: 17)
                        }
                        .accessibilityLabel("Share the recap")
                    }
                }
            }
            .task { await load() }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            JcIcon("moon.zzz", size: 34)
            Text("A quiet week").font(JcText.title).foregroundStyle(JcTheme.text)
            Text("No agent turns in the last seven days.")
                .font(JcText.body).foregroundStyle(JcTheme.muted)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func load() async {
        do {
            let r = try await api.recap()
            recap = r
            if !r.isEmpty { shareImage = Self.render(r) }
        } catch {
            self.error = apiErrorMessage(error)
        }
    }

    /// 360×640 points at 3× = 1080×1920 pixels, the size stories expect.
    @MainActor
    static func render(_ recap: AgentRecap) -> Image? {
        let card = AgentRecapCard(recap: recap, compact: false)
            .padding(28)
            .frame(width: 360, height: 640)
            .background(JcTheme.bg)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

/// The recap's numbers; the same view on screen and in the shared image.
struct AgentRecapCard: View {
    let recap: AgentRecap
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if !compact {
                    Text("MY WEEK WITH THE AGENTS")
                        .font(.system(size: 12, weight: .bold)).tracking(1.2)
                        .foregroundStyle(JcTheme.accent)
                }
                Text(recap.time)
                    .font(.system(size: compact ? 44 : 56, weight: .bold, design: .rounded))
                    .foregroundStyle(JcTheme.text)
                Text("of agent time · \(recap.sessions) session\(recap.sessions == 1 ? "" : "s")")
                    .font(JcText.body).foregroundStyle(JcTheme.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                tile("\(recap.files)", "files changed")
                tile("+\(recap.added) −\(recap.removed)", "lines")
                tile("\(recap.commands)", "commands run")
                tile("\(recap.approved)", recap.denied > 0 ? "approved · \(recap.denied) denied" : "approved")
                if recap.answered > 0 { tile("\(recap.answered)", "questions answered") }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let a = recap.topAgent { highlight("sparkles", "Top agent", a) }
                if let p = recap.topProject { highlight("folder", "Top project", p) }
                if let d = recap.busiestDay {
                    highlight("calendar", "Busiest day", "\(d) · \(AgentRecap.duration(recap.busiestMinutes))")
                }
                if let l = recap.longest { highlight("timer", "Longest session", l) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
            if !compact { Spacer(minLength: 0) }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(JcTheme.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func highlight(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            JcIcon(icon, size: 15)
            Text(label).font(.system(size: 14)).foregroundStyle(JcTheme.muted)
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(JcTheme.text)
                .lineLimit(1)
        }
    }
}
