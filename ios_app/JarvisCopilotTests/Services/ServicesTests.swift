import XCTest
@testable import JarvisCopilot

/// Services and Portfolio: the server's service pills (`/api/services`), the
/// actions they offer up close (Face ID, then the server's own confirmation
/// rule), the keys screen, and the crypto watchlist / holdings board. Both
/// lists are pushed on bridge topics while a screen shows them.
@MainActor
final class ServicesTests: XCTestCase {

    // MARK: fixtures

    private let github: [String: Any] = [
        "id": "github", "display_name": "GitHub", "tone": "warning",
        "headline": "2 PRs open · 812 contributions this year", "reason": "Review requested on api#12",
        "sections": [[
            "title": "Your pull requests", "footer": "and 3 more",
            "items": [[
                "title": "Fix the login", "subtitle": "api#12", "value": "CI passing",
                "url": "https://github.com/p/api/pull/12", "tone": "ok", "date": 1781000000.0,
                "badge": "Draft", "actions": [],
            ] as [String: Any]],
        ] as [String: Any]],
        "updated_at": 1781000100.0, "error": NSNull(),
        "extra": [
            "login": "pranav", "stats": ["repos": 41, "stars": 120],
            "activity": ["total": 812, "weeks": [
                [["date": "2026-10-04", "count": 0, "level": 0, "weekday": 0],
                 ["date": "2026-10-05", "count": 7, "level": 3, "weekday": 1]],
                [["date": "2026-10-11", "count": 2, "level": 1, "weekday": 0]],
            ]] as [String: Any],
        ] as [String: Any],
    ]

    private func vercelDetail(lastAction: [String: Any]? = nil, title: String = "app") -> [String: Any] {
        [
            "id": "vercel", "display_name": "Vercel",
            "stats": [["label": "Deploys today", "value": "4", "tone": "ok"],
                      ["label": "Failed", "value": "1", "tone": "error"]],
            "sections": [[
                "title": "Deployments",
                "items": [[
                    "title": title, "subtitle": "main · 2m", "tone": "error",
                    "url": "https://vercel.com/p/app/dpl_1",
                    "actions": [
                        ["kind": "vercel.redeploy", "title": "Redeploy", "target": "dpl_1",
                         "symbol": "arrow.clockwise", "destructive": false, "confirm": NSNull()],
                        ["kind": "vercel.cancel", "title": "Cancel", "target": "dpl_2",
                         "symbol": "xmark", "destructive": true, "confirm": "Cancel this deployment?"],
                    ] as [[String: Any]],
                ] as [String: Any]],
                "footer": NSNull(),
            ] as [String: Any]],
            "fetched_at": 1781000200.0, "error": NSNull(),
            "last_action": lastAction ?? NSNull(),
        ]
    }

    private let portfolioPayload: [String: Any] = [
        "crypto": [
            "exchange": "coinbase", "currency": "USD", "missing": ["XYZ"], "alert_symbol": NSNull(),
            "updated_at": 1781000000.0, "error": NSNull(),
            "quotes": [["symbol": "BTC", "price": 68000.5, "open_24h": 66000.0, "change_24h": 3.0311,
                        "spark": [66000, 67000.0, 68000.5], "url": "https://www.coinbase.com/advanced-trade/spot/BTC-USD"]],
        ] as [String: Any],
        "portfolio": [
            "total_usd": 1530.0, "updated_at": 1781000000.0, "error": NSNull(),
            "accounts": [[
                "id": "ethereum:0xabc", "kind": "wallet", "source": "ethereum", "name": "Ethereum",
                "label": "Cold", "address": "0xabc", "total_usd": 1530.0, "error": NSNull(),
                "holdings": [["symbol": "ETH", "amount": 0.5, "price": 3000.0, "value": 1500.0,
                              "change_24h": -1.5, "history": [3100.0, 3000.0]],
                             ["symbol": "USDC", "amount": 30, "price": 1.0, "value": 30.0,
                              "change_24h": NSNull(), "history": []]],
            ] as [String: Any]],
        ] as [String: Any],
        "ts": 1781000000.0,
    ]

    private let configPayload: [String: Any] = [
        "services": [
            ["id": "github", "display_name": "GitHub", "configured": true,
             "secrets": [["name": "token", "label": "Personal access token", "has_key": true]],
             "settings": [:] as [String: Any]],
            ["id": "n8n", "display_name": "n8n", "configured": false,
             "secrets": [["name": "api_key", "label": "API key", "has_key": false]],
             "settings": ["url": "https://n8n.example.com", "workflows": ["Daily", "Backup"]] as [String: Any]],
        ],
        "exchanges": [
            ["id": "okx", "display_name": "OKX", "configured": false,
             "secrets": [["name": "key", "label": "API key", "has_key": false],
                         ["name": "secret", "label": "API secret", "has_key": false],
                         ["name": "passphrase", "label": "Passphrase", "has_key": true]]],
        ],
        "crypto": ["enabled": true, "exchange": "okx", "currency": "EUR", "coins": ["BTC", "ETH"],
                   "alert_enabled": false, "alert_percent": 5.0,
                   "exchanges": ["coinbase", "okx"], "currencies": ["USD", "EUR"], "max_coins": 8] as [String: Any],
        "wallets": [["network": "ethereum", "address": "0xabc", "label": "Cold"]],
        "networks": [["id": "ethereum", "name": "Ethereum", "symbol": "ETH", "placeholder": "0x…"],
                     ["id": "bitcoin", "name": "Bitcoin", "symbol": "BTC", "placeholder": "bc1q…"]],
    ]

    /// Face ID stand-in: records each prompt and answers `allow`.
    final class OwnerSpy {
        var reasons: [String] = []
        var allow = true
    }

    private func makeStore(_ client: JarvisAPI, owner: OwnerSpy = OwnerSpy(),
                           topics: BridgeTopics? = nil) -> ServicesStore {
        ServicesStore(api: ServicesAPI(api: client), topics: topics ?? BridgeTopics()) { reason in
            owner.reasons.append(reason)
            return owner.allow
        }
    }

    // MARK: models

    func testSnapshotParsesSectionsItemsAndTheGitHubCalendar() {
        let s = ServiceSnapshot(json: github)
        XCTAssertEqual(s.id, "github")
        XCTAssertEqual(s.displayName, "GitHub")
        XCTAssertEqual(s.tone, .warning)
        XCTAssertEqual(s.reason, "Review requested on api#12")
        XCTAssertNil(s.error)
        XCTAssertEqual(s.updatedAt, Date(timeIntervalSince1970: 1781000100))
        XCTAssertEqual(s.sections.first?.title, "Your pull requests")
        XCTAssertEqual(s.sections.first?.footer, "and 3 more")
        let item = s.sections[0].items[0]
        XCTAssertEqual(item.title, "Fix the login")
        XCTAssertEqual(item.value, "CI passing")
        XCTAssertEqual(item.badge, "Draft")
        XCTAssertEqual(item.tone, .ok)
        XCTAssertEqual(item.url?.absoluteString, "https://github.com/p/api/pull/12")
        XCTAssertEqual(item.date, Date(timeIntervalSince1970: 1781000000))
        XCTAssertEqual(s.github?.login, "pranav")
        XCTAssertEqual(s.github?.repos, 41)
        XCTAssertEqual(s.github?.stars, 120)
        XCTAssertEqual(s.github?.total, 812)
        XCTAssertEqual(s.github?.weeks.count, 2)
        XCTAssertEqual(s.github?.weeks[0][1].level, 3)
        XCTAssertEqual(s.github?.weeks[0][1].weekday, 1)
    }

    func testSnapshotToleratesMissingAndOddFields() {
        let s = ServiceSnapshot(json: ["id": "stripe", "tone": "purple", "sections": "nope",
                                       "extra": ["login": "x"]])
        XCTAssertEqual(s.displayName, "stripe")   // falls back to the id
        XCTAssertEqual(s.tone, .idle)             // unknown tone
        XCTAssertEqual(s.headline, "")
        XCTAssertTrue(s.sections.isEmpty)
        XCTAssertNil(s.updatedAt)
        XCTAssertNil(s.github)                    // no calendar, no grid
        let odd = ServiceItem(json: ["title": "x", "url": "javascript:alert(1)", "date": "soon"], index: 0)
        XCTAssertNil(odd.url, "only web links open")
        XCTAssertNil(odd.date)
        XCTAssertTrue(odd.actions.isEmpty)
    }

    func testDetailParsesStatsActionsAndTheLastResult() {
        let d = ServiceDetail(json: vercelDetail(lastAction: ["title": "Redeploy", "ok": true,
                                                              "message": "Queued", "at": 1781000300.0]))
        XCTAssertEqual(d.id, "vercel")
        XCTAssertEqual(d.stats.map(\.label), ["Deploys today", "Failed"])
        XCTAssertEqual(d.stats[1].tone, .error)
        let actions = d.sections[0].items[0].actions
        XCTAssertEqual(actions.map(\.kind), ["vercel.redeploy", "vercel.cancel"])
        XCTAssertNil(actions[0].confirm)
        XCTAssertEqual(actions[1].confirm, "Cancel this deployment?")
        XCTAssertTrue(actions[1].destructive)
        XCTAssertNotEqual(actions[0].id, actions[1].id)
        XCTAssertEqual(d.lastAction?.message, "Queued")
        XCTAssertEqual(d.lastAction?.ok, true)
        XCTAssertNil(d.sections[0].footer)
        XCTAssertEqual(d.fetchedAt, Date(timeIntervalSince1970: 1781000200))
    }

    func testDetailWithOnlyAnErrorStillParses() {
        let d = ServiceDetail(json: ["id": "notion", "error": "No Notion key yet."])
        XCTAssertEqual(d.displayName, "notion")
        XCTAssertEqual(d.error, "No Notion key yet.")
        XCTAssertTrue(d.stats.isEmpty)
        XCTAssertTrue(d.sections.isEmpty)
        XCTAssertNil(d.lastAction)
        // An action without a kind or target can't be sent: it's dropped.
        XCTAssertNil(ServiceAction(json: ["title": "Do it"]))
    }

    func testPortfolioParsesQuotesAccountsAndHoldings() {
        let crypto = CryptoBoard(json: portfolioPayload["crypto"])
        XCTAssertEqual(crypto?.currency, "USD")
        XCTAssertEqual(crypto?.missing, ["XYZ"])
        let btc = crypto?.quotes.first
        XCTAssertEqual(btc?.symbol, "BTC")
        XCTAssertEqual(btc?.price, 68000.5)
        XCTAssertEqual(btc?.change24h ?? 0, 3.0311, accuracy: 0.0001)
        XCTAssertEqual(btc?.spark, [66000, 67000, 68000.5])
        let board = PortfolioBoard(json: portfolioPayload["portfolio"])
        XCTAssertEqual(board?.totalUSD, 1530)
        let wallet = board?.accounts.first
        XCTAssertEqual(wallet?.isWallet, true)
        XCTAssertEqual(wallet?.label, "Cold")
        XCTAssertEqual(wallet?.address, "0xabc")
        XCTAssertEqual(wallet?.holdings.map(\.symbol), ["ETH", "USDC"])
        XCTAssertEqual(wallet?.holdings[0].change24h, -1.5)
        XCTAssertNil(wallet?.holdings[1].change24h, "no 24 h change for a stablecoin")
        XCTAssertNil(CryptoBoard(json: NSNull()), "the watchlist is off")
        let bare = PortfolioBoard(json: ["accounts": [["id": "a1"]]])
        XCTAssertEqual(bare?.accounts.first?.holdings.count, 0)
        XCTAssertEqual(bare?.totalUSD, 0)
    }

    func testConfigParsesHasKeyFlagsSettingsAndWallets() {
        let c = ServicesConfig(json: configPayload)
        XCTAssertEqual(c.services.map(\.id), ["github", "n8n"])
        XCTAssertEqual(c.services[0].secrets.first?.hasKey, true)
        let n8n = c.services[1]
        XCTAssertEqual(n8n.settings.map(\.key), ["url", "workflows"])
        XCTAssertEqual(n8n.settings[0].value, .text("https://n8n.example.com"))
        XCTAssertEqual(n8n.settings[1].value, .list(["Daily", "Backup"]))
        XCTAssertEqual(c.exchanges.first?.secrets.map(\.name), ["key", "secret", "passphrase"])
        XCTAssertEqual(c.crypto?.exchange, "okx")
        XCTAssertEqual(c.crypto?.coins, ["BTC", "ETH"])
        XCTAssertEqual(c.wallets.first?.id, "ethereum:0xabc")
        XCTAssertEqual(c.networks.map(\.id), ["ethereum", "bitcoin"])
        let empty = ServicesConfig(json: [:])
        XCTAssertTrue(empty.services.isEmpty)
        XCTAssertNil(empty.crypto)
    }

    func testContributionGridKeepsTheMostRecentWeeks() {
        let activity = ServiceSnapshot(json: github).github!
        XCTAssertEqual(activity.recentWeeks(1).count, 1)
        XCTAssertEqual(activity.recentWeeks(1).first?.first?.date, "2026-10-11")
        XCTAssertEqual(activity.recentWeeks(99).count, 2)
    }

    // MARK: store: lists and pushes

    func testRefreshLoadsServicesAndPending() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services", json: ["services": [github], "pending": ["vercel"], "ts": 1.0])
        let store = makeStore(client)
        await store.refresh()
        XCTAssertEqual(store.services.map(\.id), ["github"])
        XCTAssertEqual(store.pending, ["vercel"])
        XCTAssertTrue(store.loaded)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/services")
    }

    func testServicesPushAppliesWithoutAFetch() {
        let (client, transport) = JarvisAPI.mocked()
        let topics = BridgeTopics()
        topics.send = { _ in }
        let store = makeStore(client, topics: topics)
        topics.deliver(["topic": "services", "data": ["services": [github], "ts": 2.0]])
        XCTAssertEqual(store.services.map(\.id), ["github"])
        XCTAssertEqual(store.services.first?.tone, .warning)
        XCTAssertTrue(store.loaded)
        topics.deliver(["topic": "portfolio", "data": portfolioPayload])
        XCTAssertEqual(store.crypto?.quotes.count, 1)
        XCTAssertTrue(transport.requests.isEmpty, "a push is applied as is, never followed by a fetch")
    }

    func testPushDropsServicesThatArePendingNoMore() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services", json: ["services": [], "pending": ["github", "vercel"]])
        let store = makeStore(client)
        await store.refresh()
        store.applyServices(["services": [github]])
        XCTAssertEqual(store.pending, ["vercel"])
    }

    func testPortfolioPushAppliesWithoutAFetch() {
        let (client, transport) = JarvisAPI.mocked()
        let store = makeStore(client)
        store.applyPortfolio(portfolioPayload)
        XCTAssertEqual(store.crypto?.quotes.map(\.symbol), ["BTC"])
        XCTAssertEqual(store.portfolio?.totalUSD, 1530)
        XCTAssertTrue(store.portfolioLoaded)
        store.applyPortfolio(["crypto": NSNull(), "portfolio": NSNull()])
        XCTAssertNil(store.crypto, "null means the watchlist was turned off")
        XCTAssertNil(store.portfolio)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testVisibilityWantsEachTopicOnlyWhileShown() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/portfolio", json: portfolioPayload)
        transport.route("/api/services", json: ["services": [], "pending": []])
        let topics = BridgeTopics()
        var frames: [[String: Any]] = []
        topics.send = { frames.append($0) }
        let store = makeStore(client, topics: topics)

        store.setVisible(true, feed: .services, owner: "list")
        XCTAssertTrue(topics.isWanted("services"))
        XCTAssertFalse(topics.isWanted("portfolio"))
        // The detail screen joins before the list lets go: still one fetch.
        store.setVisible(true, feed: .services, owner: "detail")
        store.setVisible(false, feed: .services, owner: "list")
        XCTAssertTrue(topics.isWanted("services"))
        store.setVisible(false, feed: .services, owner: "detail")
        XCTAssertFalse(topics.isWanted("services"))

        store.setVisible(true, feed: .portfolio, owner: "portfolio")
        XCTAssertTrue(topics.isWanted("portfolio"))
        store.setVisible(false, feed: .portfolio, owner: "portfolio")
        XCTAssertFalse(topics.isWanted("portfolio"))

        let deadline = Date().addingTimeInterval(2)
        while transport.requests.count < 2 && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        let paths = transport.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths.filter { $0 == "/api/services" }.count, 1, "fetched once when it came on screen")
        XCTAssertEqual(paths.filter { $0 == "/api/services/portfolio" }.count, 1)
        XCTAssertFalse(frames.isEmpty)
    }

    // MARK: store: actions

    func testAnActionNeedsFaceIDFirst() async {
        let (client, transport) = JarvisAPI.mocked()
        let owner = OwnerSpy()
        owner.allow = false
        let store = makeStore(client, owner: owner)
        let redeploy = ServiceDetail(json: vercelDetail()).sections[0].items[0].actions[0]
        await store.tap(redeploy, service: "vercel")
        XCTAssertEqual(owner.reasons.count, 1)
        XCTAssertTrue(owner.reasons[0].contains("Redeploy"), owner.reasons[0])
        XCTAssertTrue(transport.requests.isEmpty, "nothing is sent without Face ID")
    }

    func testASuccessfulActionUpdatesTheDetailAndSaysSo() async {
        let (client, transport) = JarvisAPI.mocked()
        let owner = OwnerSpy()
        transport.route("/api/services/vercel/action", json: [
            "ok": true, "result": ["title": "Redeploy", "ok": true, "message": "Redeploying app", "at": 1781000300.0],
            "error": NSNull(), "confirm": NSNull(),
            "detail": vercelDetail(lastAction: ["title": "Redeploy", "ok": true, "message": "Redeploying app",
                                                "at": 1781000300.0], title: "app (redeploying)"),
        ])
        let store = makeStore(client, owner: owner)
        let redeploy = ServiceDetail(json: vercelDetail()).sections[0].items[0].actions[0]
        await store.tap(redeploy, service: "vercel")

        XCTAssertEqual(owner.reasons.count, 1)
        let body = transport.lastBody()
        XCTAssertEqual(body["kind"] as? String, "vercel.redeploy")
        XCTAssertEqual(body["target"] as? String, "dpl_1")
        XCTAssertEqual(body["confirmed"] as? Bool, false)
        XCTAssertNotNil(body["requested_at"] as? Double)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(store.details["vercel"]?.sections.first?.items.first?.title, "app (redeploying)")
        XCTAssertEqual(store.details["vercel"]?.lastAction?.message, "Redeploying app")
        XCTAssertTrue(store.toast?.contains("Redeploying app") == true, store.toast ?? "nil")
        XCTAssertTrue(store.running.isEmpty)
        XCTAssertNil(store.pendingConfirmation)
    }

    func testAConflictWithAQuestionAsksItThenResendsConfirmed() async {
        let (client, transport) = JarvisAPI.mocked()
        let owner = OwnerSpy()
        transport.enqueue(json: ["ok": false, "result": NSNull(), "error": "This action needs confirmation.",
                                 "confirm": "Merge api#12?", "detail": vercelDetail()], status: 409)
        transport.enqueue(json: ["ok": true, "result": ["title": "Merge", "ok": true, "message": "Merged", "at": 1.0],
                                 "detail": vercelDetail()], status: 200)
        let store = makeStore(client, owner: owner)
        let merge = ServiceAction(json: ["kind": "github.merge", "title": "Merge", "target": "api#12"])!
        await store.tap(merge, service: "github")

        let question = store.pendingConfirmation
        XCTAssertEqual(question?.question, "Merge api#12?")
        XCTAssertEqual(question?.serviceID, "github")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.lastBody()["confirmed"] as? Bool, false)

        await store.confirm(question!)
        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.lastBody()["confirmed"] as? Bool, true)
        XCTAssertEqual(owner.reasons.count, 1, "Face ID once: the question came after it")
        XCTAssertEqual(store.toast, "Merge: Merged")
    }

    func testAKnownQuestionIsAskedBeforeFaceID() async {
        let (client, transport) = JarvisAPI.mocked()
        let owner = OwnerSpy()
        transport.route("/api/services/vercel/action", json: [
            "ok": true, "result": ["title": "Cancel", "ok": true, "message": "Canceled", "at": 1.0],
            "detail": vercelDetail()])
        let store = makeStore(client, owner: owner)
        let cancel = ServiceDetail(json: vercelDetail()).sections[0].items[0].actions[1]
        await store.tap(cancel, service: "vercel")
        XCTAssertEqual(store.pendingConfirmation?.question, "Cancel this deployment?")
        XCTAssertTrue(owner.reasons.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)

        store.cancelPending()
        XCTAssertNil(store.pendingConfirmation)

        await store.tap(cancel, service: "vercel")
        await store.confirm(store.pendingConfirmation!)
        XCTAssertEqual(owner.reasons.count, 1)
        XCTAssertEqual(transport.lastBody()["confirmed"] as? Bool, true)
        XCTAssertEqual(transport.lastBody()["kind"] as? String, "vercel.cancel")
    }

    func testARefusalShowsWhyAndTheFreshList() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/vercel/action", json: [
            "ok": false, "result": NSNull(), "error": "This list is out of date. It was refreshed; try again.",
            "confirm": NSNull(), "detail": vercelDetail(title: "fresh")], status: 409)
        let store = makeStore(client)
        let redeploy = ServiceDetail(json: vercelDetail()).sections[0].items[0].actions[0]
        await store.tap(redeploy, service: "vercel")
        XCTAssertNil(store.pendingConfirmation)
        XCTAssertEqual(store.toast, "This list is out of date. It was refreshed; try again.")
        XCTAssertEqual(store.details["vercel"]?.sections.first?.items.first?.title, "fresh")
    }

    func testAFailedServiceCallSaysWhatWentWrong() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/vercel/action", json: [
            "ok": false, "result": ["title": "Redeploy", "ok": false, "message": "Vercel is having trouble (503).", "at": 1.0],
            "error": "Vercel is having trouble (503).", "confirm": NSNull(), "detail": vercelDetail()], status: 502)
        let store = makeStore(client)
        let redeploy = ServiceDetail(json: vercelDetail()).sections[0].items[0].actions[0]
        await store.tap(redeploy, service: "vercel")
        XCTAssertEqual(store.toast, "Redeploy: Vercel is having trouble (503).")
        XCTAssertNotNil(store.details["vercel"])
    }

    func testAnUnreadableErrorPageIsStillAnError() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.enqueue(text: "<html>Bad gateway</html>", status: 502, contentType: "text/html")
        let store = makeStore(client)
        let redeploy = ServiceDetail(json: vercelDetail()).sections[0].items[0].actions[0]
        await store.tap(redeploy, service: "vercel")
        XCTAssertEqual(store.toast, "Request failed (502)")
    }

    func testLoadDetailKeepsItPerService() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/vercel/detail", json: vercelDetail())
        let store = makeStore(client)
        await store.loadDetail("vercel")
        XCTAssertEqual(store.details["vercel"]?.stats.count, 2)
        XCTAssertNil(store.detailErrors["vercel"])
        XCTAssertEqual(transport.lastRequest?.httpMethod, "GET")
    }

    // MARK: store: keys and settings

    func testASavedKeyIsNeverResentAndOnlyTypedSecretsGoOut() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/config", json: configPayload)
        let store = makeStore(client)
        await store.loadConfig()
        let github = store.config!.services[0]

        // Nothing typed: nothing to send, no request at all.
        var draft = KeysDraft()
        draft.typed["token"] = "   "
        let none = await store.saveService(github, draft: draft)
        XCTAssertFalse(none)
        XCTAssertEqual(transport.requests.count, 1, "only the config load")

        draft.typed["token"] = "ghp_new_token_123"
        draft.typed["not_a_field"] = "leftover"
        let saved = await store.saveService(github, draft: draft)
        XCTAssertTrue(saved)
        let body = transport.lastBody()
        XCTAssertEqual(body["service"] as? String, "github")
        XCTAssertEqual(body["secrets"] as? [String: String], ["token": "ghp_new_token_123"])
        XCTAssertNil(body["settings"], "settings untouched: not sent")
    }

    func testOnlyTheExchangeFieldsYouTypedAreSent() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/config", json: configPayload)
        let store = makeStore(client)
        await store.loadConfig()
        let okx = store.config!.exchanges[0]
        var draft = KeysDraft()
        draft.typed = ["key": "k-12345678", "secret": "s-12345678"]   // passphrase is saved; left alone
        _ = await store.saveExchange(okx, draft: draft)
        let body = transport.lastBody()
        XCTAssertEqual(body["exchange"] as? String, "okx")
        let secrets = body["secrets"] as? [String: Any]
        XCTAssertEqual(Set(secrets?.keys.map { $0 } ?? []), ["key", "secret"])
        XCTAssertNil(secrets?["passphrase"])
    }

    func testRemovingAKeySendsNullAndChangedSettingsGoAsTheirType() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/config", json: configPayload)
        let store = makeStore(client)
        await store.loadConfig()
        let n8n = store.config!.services[1]
        var draft = KeysDraft()
        draft.removed = ["api_key"]
        draft.settings = ["url": "https://n8n.example.com", "workflows": "Daily, Sync ,, Backup"]
        _ = await store.saveService(n8n, draft: draft)
        let body = transport.lastBody()
        let secrets = body["secrets"] as? [String: Any]
        XCTAssertTrue(secrets?["api_key"] is NSNull)
        let settings = body["settings"] as? [String: Any]
        XCTAssertNil(settings?["url"], "unchanged")
        XCTAssertEqual(settings?["workflows"] as? [String], ["Daily", "Sync", "Backup"])
    }

    func testCryptoSettingsAndWallets() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/config", json: configPayload)
        transport.route("/api/services/portfolio/wallets", json: [
            "ok": true, "wallets": [["network": "ethereum", "address": "0xabc", "label": "Cold"],
                                    ["network": "bitcoin", "address": "bc1qxyz", "label": ""]],
            "holdings": [["symbol": "BTC", "amount": 0.1]]])
        let store = makeStore(client)
        await store.loadConfig()

        _ = await store.saveCrypto(["enabled": true, "coins": "btc, sol"])
        let crypto = transport.lastBody()["crypto"] as? [String: Any]
        XCTAssertEqual(crypto?["enabled"] as? Bool, true)
        XCTAssertEqual(crypto?["coins"] as? String, "btc, sol")
        XCTAssertEqual(crypto?.count, 2, "only what changed")

        let error = await store.addWallet(network: "bitcoin", address: " bc1qxyz ", label: "")
        XCTAssertNil(error)
        let body = transport.lastBody()
        XCTAssertEqual(body["op"] as? String, "add")
        XCTAssertEqual(body["network"] as? String, "bitcoin")
        XCTAssertEqual(body["address"] as? String, "bc1qxyz")
        XCTAssertEqual(store.config?.wallets.map(\.id), ["ethereum:0xabc", "bitcoin:bc1qxyz"])

        _ = await store.removeWallet(store.config!.wallets[0])
        XCTAssertEqual(transport.lastBody()["op"] as? String, "remove")
        XCTAssertEqual(transport.lastBody()["address"] as? String, "0xabc")
    }

    func testABadWalletAddressComesBackAsTheServersWords() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/services/portfolio/wallets",
                        json: ["error": "That doesn't look like a Bitcoin address (bc1q… or 1… or 3…)."], status: 400)
        let store = makeStore(client)
        let error = await store.addWallet(network: "bitcoin", address: "nope", label: "")
        XCTAssertEqual(error, "That doesn't look like a Bitcoin address (bc1q… or 1… or 3…).")
    }

    // MARK: formatting

    func testFormatting() {
        XCTAssertEqual(ServicesFormat.percent(3.0311), "+3.03%")
        XCTAssertEqual(ServicesFormat.percent(-1.5), "−1.50%")
        XCTAssertEqual(ServicesFormat.priceDigits(68000), 0)
        XCTAssertEqual(ServicesFormat.priceDigits(12.5), 2)
        XCTAssertEqual(ServicesFormat.priceDigits(0.12), 4)
    }
}
