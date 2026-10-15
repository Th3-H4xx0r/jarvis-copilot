import SwiftUI

/// Where the Portfolio screens push, inside More's stack.
enum PortfolioRoute: Hashable {
    case settings
    case exchangeKeys
}

/// Portfolio: the crypto watchlist (prices, the day's curve, 24 h change) and
/// what your exchange accounts and public wallets hold, valued in dollars.
/// Live while on screen from the `portfolio` topic.
struct PortfolioPage: View {
    var store: ServicesStore = .shared

    private var nothingSetUp: Bool {
        store.portfolioLoaded && store.crypto == nil && store.portfolio == nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error = store.portfolioError, store.crypto == nil, store.portfolio == nil {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
                if let board = store.portfolio { totalCard(board) }
                if let crypto = store.crypto { watchlist(crypto) }
                if let board = store.portfolio {
                    if let error = board.error { problem(error) }
                    if !board.accounts.isEmpty { SectionHeader("Holdings").padding(.top, 4) }
                    ForEach(board.accounts) { account in AccountCard(account: account) }
                }
                if nothingSetUp && store.portfolioError == nil { emptyState }
                if !store.portfolioLoaded && store.portfolioError == nil {
                    ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .refreshable { await store.refreshPortfolio() }
        .jcScreen("Portfolio")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: PortfolioRoute.settings) {
                    JcIcon("slider.horizontal.3", size: 17)
                }
                .accessibilityLabel("Watchlist, wallets and exchanges")
            }
        }
        .navigationDestination(for: PortfolioRoute.self) { route in
            switch route {
            case .settings: PortfolioSettingsScreen(store: store)
            case .exchangeKeys: ServiceKeysScreen(scope: .exchanges, store: store)
            }
        }
        .servicesVisibility { store.setVisible($0, feed: .portfolio, owner: "portfolio-page") }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3.5)
    }

    // MARK: total

    private func totalCard(_ board: PortfolioBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TOTAL")
                .font(.system(size: 11.5, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(JcTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ServicesFormat.usd(board.totalUSD))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(JcTheme.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let change = PortfolioMath.change24h(board) {
                    Text(ServicesFormat.percent(change))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ServicesStyle.change(change))
                }
            }
            Text(totalLine(board))
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func totalLine(_ board: PortfolioBoard) -> String {
        let n = board.accounts.count
        var parts = ["\(n) account\(n == 1 ? "" : "s")", "in USD"]
        if let updated = board.updatedAt { parts.append("updated \(ServicesFormat.agoPhrase(updated))") }
        return parts.joined(separator: " · ")
    }

    // MARK: watchlist

    private func watchlist(_ crypto: CryptoBoard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Watchlist") {
                Text("\(PortfolioMath.exchangeName(crypto.exchange)) · \(crypto.currency)")
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
            }
            if let error = crypto.error {
                problem(error).padding(.bottom, 8)
            }
            if crypto.quotes.isEmpty {
                Text(crypto.error == nil ? "Waiting for the first prices…" : "No prices right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 4)
            } else {
                GlassGroup {
                    ForEach(crypto.quotes) { quote in
                        QuoteRow(quote: quote, currency: crypto.currency, alerted: crypto.alertSymbol == quote.symbol)
                        if quote.id != crypto.quotes.last?.id {
                            Divider().overlay(JcTheme.glassBorder).padding(.leading, 14)
                        }
                    }
                }
            }
            if !crypto.missing.isEmpty {
                Text("No price for \(crypto.missing.joined(separator: ", ")) on \(PortfolioMath.exchangeName(crypto.exchange)).")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.amber)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: empty / errors

    private func problem(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            JcIcon("exclamationmark.circle", size: 14).foregroundStyle(JcTheme.danger).padding(.top, 1)
            Text(message).font(.system(size: 13)).foregroundStyle(JcTheme.text)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(JcTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.danger.opacity(0.35), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing to show yet")
                .font(.system(size: 16, weight: .semibold))
            Text("Turn on the watchlist for live prices, add a public wallet address, or connect a read-only exchange key to see what you hold.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
            NavigationLink(value: PortfolioRoute.settings) {
                Label("Set it up", jcIcon: "slider.horizontal.3")
            }
            .buttonStyle(.jcGlass(compact: true))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }
}

/// One coin on the watchlist: price, the day's hourly curve, the 24 h change.
private struct QuoteRow: View {
    let quote: CryptoQuote
    let currency: String
    let alerted: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = quote.url { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(quote.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                        if alerted {
                            JcIcon("bell", size: 11)
                                .foregroundStyle(JcTheme.amber)
                                .accessibilityLabel("Alerted")
                        }
                    }
                    Text(ServicesFormat.price(quote.price, currency: currency))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                ServicesSparkline(values: quote.spark, color: ServicesStyle.change(quote.change24h))
                    .frame(width: 76, height: 26)
                Text(ServicesFormat.percent(quote.change24h))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ServicesStyle.change(quote.change24h))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(quote.url == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quote.symbol), \(ServicesFormat.price(quote.price, currency: currency)), \(ServicesFormat.percent(quote.change24h)) today")
    }
}

/// An exchange account or a wallet: its total and what it holds.
private struct AccountCard: View {
    let account: PortfolioAccount

    private var subtitle: String {
        if account.isWallet {
            let short = account.address.map(PortfolioMath.shortAddress) ?? ""
            return [account.name + " wallet", short].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return "Exchange"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                JcIcon(account.isWallet ? "wallet.pass" : "building.columns", size: 15)
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(JcTheme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(ServicesFormat.usd(account.totalUSD))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .monospacedDigit()
            }
            if let error = account.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.danger)
            } else if account.holdings.isEmpty {
                Text("Empty.")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            ForEach(account.holdings) { holding in HoldingRow(holding: holding) }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HoldingRow: View {
    let holding: PortfolioHolding

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                Text(ServicesFormat.amount(holding.amount))
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if holding.history.count > 1 {
                ServicesSparkline(values: holding.history,
                                  color: ServicesStyle.change(holding.change24h ?? 0))
                    .frame(width: 56, height: 20)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(ServicesFormat.usd(holding.value))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .monospacedDigit()
                if let change = holding.change24h {
                    Text(ServicesFormat.percent(change))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ServicesStyle.change(change))
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.leading, 40)
        .accessibilityElement(children: .combine)
    }
}

/// A price curve: the line, and a wash of its colour underneath.
struct ServicesSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        ZStack {
            JCSparklineShape(points: values, filled: true)
                .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            JCSparklineShape(points: values, filled: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Settings

/// The watchlist's settings, the public wallets, and the exchange keys.
struct PortfolioSettingsScreen: View {
    var store: ServicesStore = .shared

    @State private var form: CryptoOptions?
    @State private var coinsText = ""
    @State private var addingWallet = false
    @State private var removing: WalletEntry?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let config = store.config {
                    if form != nil { watchlistCard }
                    walletsCard(config)
                    exchangesCard(config)
                } else if let error = store.configError {
                    Text(error).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
                } else {
                    ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity).padding(.top, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .jcScreen("Portfolio settings")
        .task { await store.loadConfig() }
        .onChange(of: store.config?.crypto, initial: true) { _, crypto in
            form = crypto
            coinsText = crypto?.coins.joined(separator: ", ") ?? ""
        }
        .sheet(isPresented: $addingWallet) {
            AddWalletSheet(store: store, networks: store.config?.networks ?? [])
        }
        .alert("Remove this wallet?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { wallet in
            Button("Remove", role: .destructive) { Task { await store.removeWallet(wallet) } }
            Button("Cancel", role: .cancel) {}
        } message: { wallet in
            Text("\(wallet.label.isEmpty ? PortfolioMath.shortAddress(wallet.address) : wallet.label) stops showing in the portfolio. The wallet itself isn't touched.")
        }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3.5)
    }

    // MARK: watchlist

    /// Only what changed goes to the server.
    private var changes: [String: Any] {
        guard let original = store.config?.crypto, let form else { return [:] }
        var out: [String: Any] = [:]
        if form.enabled != original.enabled { out["enabled"] = form.enabled }
        if form.exchange != original.exchange { out["exchange"] = form.exchange }
        if form.currency != original.currency { out["currency"] = form.currency }
        if PortfolioMath.coins(coinsText) != original.coins { out["coins"] = coinsText }
        if form.alertEnabled != original.alertEnabled { out["alert_enabled"] = form.alertEnabled }
        if abs(form.alertPercent - original.alertPercent) > 0.001 { out["alert_percent"] = form.alertPercent }
        return out
    }

    private func formBinding<T>(_ key: WritableKeyPath<CryptoOptions, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { form?[keyPath: key] ?? fallback },
                set: { form?[keyPath: key] = $0 })
    }

    private var watchlistCard: some View {
        let options = form
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Watchlist")
            Toggle(isOn: formBinding(\.enabled, false)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live prices").font(.system(size: 15, weight: .medium))
                    Text("Public market data, no account needed.").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
            .tint(JcTheme.accent)
            if options?.enabled == true {
                labelled("Prices from") {
                    Picker("Prices from", selection: formBinding(\.exchange, "coinbase")) {
                        ForEach(options?.exchanges ?? [], id: \.self) { Text(PortfolioMath.exchangeName($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                labelled("Currency") {
                    Picker("Currency", selection: formBinding(\.currency, "USD")) {
                        ForEach(options?.currencies ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                labelled("Coins (up to \(options?.maxCoins ?? 8))") {
                    TextField("BTC, ETH, SOL", text: $coinsText)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Toggle(isOn: formBinding(\.alertEnabled, false)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alert on big moves").font(.system(size: 15, weight: .medium))
                        Text("A notification when a coin moves this much since the last alert.")
                            .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                }
                .tint(JcTheme.accent)
                if options?.alertEnabled == true {
                    Stepper(value: formBinding(\.alertPercent, 5), in: 0.5...50, step: 0.5) {
                        Text("At ±\(String(format: "%.1f", options?.alertPercent ?? 5))%")
                            .font(.system(size: 14))
                            .monospacedDigit()
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    let body = changes
                    Task { await store.saveCrypto(body) }
                } label: {
                    HStack(spacing: 6) {
                        if store.saving { ProgressView().controlSize(.mini).tint(JcTheme.accent) }
                        Text("Save")
                    }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(changes.isEmpty || store.saving)
            }
        }
        .foregroundStyle(JcTheme.text)
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(JcTheme.muted)
            content()
        }
    }

    // MARK: wallets

    private func walletsCard(_ config: ServicesConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Wallets") {
                Button { addingWallet = true } label: { Label("Add", jcIcon: "plus") }
                    .buttonStyle(.jcGlass(compact: true))
                    .disabled(config.networks.isEmpty)
            }
            if config.wallets.isEmpty {
                Text("Public addresses only: Jarvis reads the balance, never a key.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
            }
            ForEach(config.wallets) { wallet in
                HStack(spacing: 10) {
                    JcIcon("wallet.pass", size: 14).foregroundStyle(JcTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallet.label.isEmpty ? PortfolioMath.shortAddress(wallet.address) : wallet.label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Text("\(config.network(wallet.network)?.name ?? wallet.network) · \(PortfolioMath.shortAddress(wallet.address))")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button("Remove") { removing = wallet }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                }
            }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    // MARK: exchanges

    private func exchangesCard(_ config: ServicesConfig) -> some View {
        NavigationLink(value: PortfolioRoute.exchangeKeys) {
            HStack(spacing: 10) {
                JcIcon("building.columns", size: 14).foregroundStyle(JcTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exchange accounts")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                    Text(exchangeLine(config))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted)
            }
            .padding(14)
            .contentShape(Rectangle())
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func exchangeLine(_ config: ServicesConfig) -> String {
        let connected = config.exchanges.filter(\.configured).map(\.displayName)
        if connected.isEmpty { return config.exchanges.map(\.displayName).joined(separator: ", ") }
        return "Connected: " + connected.joined(separator: ", ")
    }
}

/// Add a public wallet: pick the network, paste the address, name it if you like.
private struct AddWalletSheet: View {
    let store: ServicesStore
    let networks: [WalletNetwork]

    @Environment(\.dismiss) private var dismiss
    @State private var network = ""
    @State private var address = ""
    @State private var label = ""
    @State private var error: String?
    @State private var busy = false

    private var selected: WalletNetwork? { networks.first { $0.id == network } ?? networks.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add a wallet").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Network").font(.system(size: 12, weight: .semibold)).foregroundStyle(JcTheme.muted)
                Picker("Network", selection: $network) {
                    ForEach(networks) { Text("\($0.name) (\($0.symbol))").tag($0.id) }
                }
                .pickerStyle(.menu)
                .tint(JcTheme.accent)
            }
            field("Address", text: $address, placeholder: selected?.placeholder ?? "", mono: true)
            field("Name (optional)", text: $label, placeholder: "Cold storage", mono: false)
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
            }
            Text("Only the public address. Jarvis reads its balance from a public explorer, never a key.")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
            HStack {
                Spacer()
                Button {
                    busy = true
                    error = nil
                    Task {
                        let problem = await store.addWallet(network: selected?.id ?? network, address: address, label: label)
                        busy = false
                        if let problem { error = problem } else { dismiss() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.mini).tint(JcTheme.accent) }
                        Text(busy ? "Checking…" : "Add")
                    }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(JcTheme.text)
        .padding(20)
        .presentationDetents([.medium, .large])
        .presentationBackground(JcTheme.surface)
        .onAppear { if network.isEmpty { network = networks.first?.id ?? "" } }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(JcTheme.muted)
            TextField(placeholder, text: text)
                .font(.system(size: 14, design: mono ? .monospaced : .default))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Math

enum PortfolioMath {
    /// The whole portfolio's move over 24 h, weighted by what each holding is
    /// worth (holdings without a 24 h change count as flat). Nil when nothing moved.
    static func change24h(_ board: PortfolioBoard) -> Double? {
        var now = 0.0, before = 0.0, priced = false
        for holding in board.accounts.flatMap(\.holdings) {
            now += holding.value
            if let change = holding.change24h, change > -100 {
                before += holding.value / (1 + change / 100)
                priced = true
            } else {
                before += holding.value
            }
        }
        guard priced, before > 0 else { return nil }
        return (now - before) / before * 100
    }

    static func exchangeName(_ id: String) -> String {
        switch id.lowercased() {
        case "okx": return "OKX"
        case "coinbase": return "Coinbase"
        default: return id.capitalized
        }
    }

    /// "0x1234…abcd".
    static func shortAddress(_ address: String) -> String {
        address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
    }

    /// The server's own reading of a coin list: letters and digits, upper case,
    /// no repeats.
    static func coins(_ text: String) -> [String] {
        var out: [String] = []
        for token in text.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        where !token.isEmpty && token.count <= 10 && !out.contains(token) {
            out.append(token)
        }
        return out
    }
}
