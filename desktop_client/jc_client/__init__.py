"""JarvisCopilot desktop client.

Long-lived background process that connects to a JarvisCopilot server,
registers a catalog of platform-native skills (open apps, mouse/keyboard
control, screenshot, notify, …), and executes invocations the agent
sends back over a paired WebSocket bridge.

Layout:
    cli.py          argparse entry point (`jc-client pair`, etc.)
    service.py      main connect-loop + dispatcher
    protocol.py     wsproto wrapper (sync, threaded I/O)
    credentials.py  keyring-backed config (server URL + session cookie +
                    pinned TLS fingerprint)
    pair_ui.py      tkinter first-run dialog
    tray.py         pystray menu + status indicator
    skills/         skill registry + platform-specific implementations
"""

__version__ = "0.1.0"
