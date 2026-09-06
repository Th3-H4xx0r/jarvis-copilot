import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Shared scaffolding for the wave-2B UI tests (the second half of the More
/// pages, plus Devices and Skills).
///
/// The hosting smoke tests answer one question the store tests can't: does the
/// SwiftUI body actually build and lay out for this state? A view that reads a
/// nil optional, divides by a zero total or recurses through a bad `ForEach`
/// only fails when something renders it.

/// Render a view through `UIHostingController` and force a layout pass. Fails
/// the test if the body traps.
@MainActor
func moreUIBHost<V: View>(_ view: V,
                          size: CGSize = CGSize(width: 393, height: 852),
                          file: StaticString = #filePath, line: UInt = #line) {
    let host = UIHostingController(rootView: view)
    host.view.frame = CGRect(origin: .zero, size: size)
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    XCTAssertEqual(host.view.bounds.size, size, "hosted view lost its frame",
                   file: file, line: line)
}

// MARK: - Fixtures

enum MoreUIBFixtures {

    static let insightsOverview: [String: Any] = [
        "period_days": 30,
        "total_sessions": 42,
        "total_messages": 318,
        "total_input_tokens": 1_240_000,
        "total_output_tokens": 260_000,
        "total_tokens": 1_500_000,
        "total_cost": 12.345,
        "models": [
            ["model": "claude-opus", "sessions": 30, "total_tokens": 1_200_000,
             "cost": 10.5, "cost_share": 85.2],
            ["model": "gpt-5", "sessions": 12, "total_tokens": 300_000,
             "cost": 1.845, "cost_share": 14.8],
        ],
        "daily_tokens": [
            ["date": "2026-06-19", "input_tokens": 0, "output_tokens": 0],
            ["date": "2026-06-20", "input_tokens": 120_000, "output_tokens": 30_000],
            ["date": "2026-06-21", "input_tokens": 90_000, "output_tokens": 22_000],
        ],
        "activity_by_day": [["day": "Mon", "sessions": 6], ["day": "Tue", "sessions": 9]],
        "activity_by_hour": [["hour": 9, "sessions": 4], ["hour": 21, "sessions": 11]],
    ]

    static let systemHealth: [String: Any] = [
        "status": "ok",
        "available": true,
        "checked_at": "2026-06-21T09:30:00Z",
        "cpu": ["percent": 41.5],
        "memory": ["percent": 72, "used_bytes": 6_000_000_000, "total_bytes": 8_000_000_000],
        "disk": ["percent": 93.2, "used_bytes": 90_000_000_000, "total_bytes": 100_000_000_000],
    ]

    static let wikiStatus: [String: Any] = [
        "available": true, "enabled": true, "status": "ready",
        "entry_count": 1234, "page_count": 88, "raw_source_count": 12,
        "last_updated": "2026-06-21T09:30:00Z", "last_writer": "jarvis",
    ]

    static let sessions: [String: Any] = [
        "sessions": [["session_id": "s-1", "updated_at": "2026-06-21T09:30:00Z"]],
    ]

    static let insightsMessages: [String: Any] = [
        "messages": [
            ["turn": 1, "timestamp": "2026-06-21T09:30:00Z", "model": "claude-opus",
             "input_tokens": 12_000, "output_tokens": 900, "cache_read_tokens": 4_000,
             "latency_s": 2.4,
             "composition": ["sections": ["identity": 900, "memory": 4200,
                                          "conversation_history": 6900]]],
            ["turn": 2, "timestamp": "2026-06-21T09:31:00Z", "model": "claude-opus",
             "input_tokens": 13_500, "output_tokens": 1_400, "composition": [:]],
        ],
    ]

    static let quota: [String: Any] = [
        "providers": [
            ["provider": "claude-code", "display_name": "Claude Code", "plan": "Max",
             "details": ["Resets on the rolling 5-hour window."],
             "windows": [
                ["label": "Current session", "used_percent": 46.2,
                 "reset_at": "2099-01-01T00:00:00Z", "detail": "Opus + Sonnet"],
                ["label": "Current week", "remaining_percent": 4],
                ["label": "Unknown window"],
             ]],
            ["provider": "openai-codex", "display_name": "Codex", "windows": []],
        ],
    ]

    static let workspaces: [String: Any] = [
        "workspaces": [
            ["path": "/Users/me/code/jarvis", "name": "Jarvis"],
            ["path": "/Users/me/code/wearables", "name": "Wearables"],
            "/Users/me/scratch",
        ],
        "last": "/Users/me/code/wearables",
    ]

    static let logs: [String: Any] = [
        "file": "agent", "tail": 1000, "truncated": true,
        "total_bytes": 2_400_000, "mtime": 1_781_000_000,
        "hint": "Nothing logged yet.",
        "lines": [
            "2026-06-21 09:30:00 INFO  started",
            "2026-06-21 09:30:02 WARNING slow reply",
            "2026-06-21 09:30:04 ERROR boom",
            "Traceback (most recent call last):",
        ],
    ]

    static let profiles: [String: Any] = [
        "active": "default",
        "profiles": [
            ["name": "default", "path": "/p/default", "model": "claude-opus",
             "provider": "anthropic", "is_default": true, "gateway_running": true],
            ["name": "work", "path": "/p/work", "default_model": "gpt-5",
             "model_provider": "openai"],
        ],
    ]

    static let personality: [String: Any] = ["prompt": "You are JARVIS. Be brief."]

    static let selfImprovement: [String: Any] = [
        "entries": [
            ["kind": "change", "origin": "skills/notes.py", "ts": "2026-06-21T09:30:00Z",
             "text": "Added a note-taking skill."],
            ["kind": "fail", "origin": "memory", "ts": 1_781_000_000,
             "text": "Could not write MEMORY.md."],
            ["kind": "rejected", "text": "Refused an unsafe patch."],
        ],
    ]

    static let islandCatalog: [String: Any] = [
        "selection": ["mode": "pinned", "pinnedId": "voice"],
        "catalog": [
            ["id": "voice", "name": "Voice", "builtin": true, "enabled": true, "priority": 10],
            ["id": "coding", "name": "Coding", "builtin": true, "enabled": false, "priority": 5],
            ["id": "meeting", "name": "Next meeting", "enabled": true, "priority": 1],
        ],
        "designs": [["id": "meeting", "name": "Next meeting", "version": 2]],
    ]

    static let photon: [String: Any] = [
        "configured": true,
        "project_id": "proj_abc",
        "project_secret_set": true,
        "notify_target": "+15550001111",
        "sidecar_url": "http://127.0.0.1:8787",
        "sidecar_token_set": false,
        "allowed_users": "",
        "allow_all": true,
        "sidecar": ["reachable": true, "ok": true, "mock": true],
        "fields": [["key": "project_id", "label": "Project ID", "required": true]],
    ]

    static let devices: [String: Any] = [
        "devices": [
            ["id": "d-1", "label": "Pranav's iPhone", "platform": "mobile-ios",
             "online": true, "last_seen": 1_781_000_000,
             "skills": [["name": "copy_text", "allowed": true],
                        ["name": "open_app", "allowed": false]]],
            ["id": "d-2", "label": "MacBook Pro", "platform": "browser",
             "online": false, "last_seen": "2026-06-20T09:30:00Z", "skills": []],
        ],
    ]

    static let deviceSkills: [String: Any] = [
        "skills": [
            ["name": "copy_text", "title": "Copy text", "description": "Clipboard"],
            ["name": "open_app", "title": "Open app"],
        ],
    ]
}
