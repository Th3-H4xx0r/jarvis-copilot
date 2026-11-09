"""``jarviscopilot security`` — break-glass from an SSH shell.

Works straight from the files under the profile's ``security/`` folder, so a
mistaken block can be cleared even when the webui is down; the running webui
picks the change up on its next request.
"""
from __future__ import annotations

import argparse


def register_cli(subparser: argparse.ArgumentParser) -> None:
    subs = subparser.add_subparsers(dest="security_command")
    subs.add_parser("status", help="Advisor status and active IP blocks")
    unblock = subs.add_parser("unblock", help="Lift an IP block (or all of them)")
    unblock.add_argument("ip", nargs="?", help="The IP address to unblock")
    unblock.add_argument("--all", action="store_true", help="Lift every block")


def _status() -> int:
    from plugins.security_advisor.service import SecurityService, snapshot
    from security.blocklist import default_blocklist
    from security.events import default_log
    log, blocks = default_log(), default_blocklist()
    running = SecurityService._instance
    st = running.status() if running is not None else snapshot(log, blocks, chain_ok=log.verify_chain() is None)
    print(f"Security Advisor: {st['state']} ({st['open_alerts']} open alerts)")
    print(f"Last event: {st['last_event'] or 'none'}   Event log intact: {'yes' if st['chain_ok'] else 'NO'}")
    active = blocks.active()
    print(f"Blocked IPs: {len(active)}")
    for b in active:
        print(f"  {b['ip']}  {b.get('reason') or ''}")
    return 0


def security_command(args: argparse.Namespace) -> int:
    sub = getattr(args, "security_command", None)
    if sub == "status":
        return _status()
    if sub == "unblock":
        from security.blocklist import default_blocklist
        blocks = default_blocklist()
        if getattr(args, "all", False):
            print(f"Unblocked {blocks.unblock_all()} IP(s).")
            return 0
        if not args.ip:
            print("usage: jarviscopilot security unblock <ip> | --all")
            return 2
        if blocks.unblock(args.ip):
            print(f"Unblocked {args.ip}.")
            return 0
        print(f"{args.ip} was not blocked.")
        return 1
    print("usage: jarviscopilot security {status,unblock}")
    return 2
