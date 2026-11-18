"""Which PC commands need his Face ID: deletes, uninstalls, registry writes, disk/boot changes, service
removal, stopping processes he didn't name, turning off protections, unreadable code, power — and, as a last
net, anything that says it removes, deletes, uninstalls or disables something. A false positive only costs a
Face ID prompt; a miss could cost his files — so every segment is checked, quoted command words count
(`cmd /c "rd /s /q …"`), and the generic net stays even where a specific rule exists."""
from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass
class Verdict:
    destructive: bool
    refuse: bool
    reason: str


# A command word starts the segment or follows a separator — quotes and commas included, so
# `cmd /c "del …"` and `-ArgumentList '/c','del …'` are read like `del …`.
# Sleeping or locking the PC (the Agents card's buttons and computer_power do these, never IT steps).
POWER_ACTION = re.compile(r"\bsetsuspendstate\b|\blockworkstation\b|\bsuspend-computer\b", re.I)
_W = r"(?:^|(?<=[\s(;{|&\"'`,]))"
_RULES = [
    ("deletes files", re.compile(
        _W + r"(?:remove-item|ri|rm|del|erase|rd|rmdir|clear-content|clear-recyclebin|clear-item)(?=[\s\"']|$)|"
        r"\.delete\w*\(|\[(?:system\.)?io\.(?:file|directory)\]::delete|\bcipher(?:\.exe)?\s+/w|\bgit\s+clean\b|"
        r"\bgit\s+reset\s+--hard\b|\brobocopy(?:\.exe)?\b[^\n]*?/(?:mir|purge|mov|move)\b|\bsdelete\b", re.I)),
    ("uninstalls software", re.compile(
        r"\buninstall|\bunins\d*\.exe\b|\bwinget(?:\.exe)?\s+remove\b|\bmsiexec(?:\.exe)?\b[^\n]*?/x\b|"
        r"\bremove-appx\w*package\b|\bdisable-windowsoptionalfeature\b|\bdism(?:\.exe)?\b[^\n]*?/disable-feature|"
        r"\bwsl(?:\.exe)?\s+--unregister\b", re.I)),
    ("changes the registry", re.compile(
        r"\breg(?:\.exe)?[\"']?\s+(?:add|delete|import|restore|load|unload|copy)\b|\bregedit(?:\.exe)?[\"']?\s+/s\b|"
        r"\b(?:set|new|remove|rename)-itemproperty\b|"
        r"\b(?:set|new|remove|rename|clear|copy|move)-item\b[^\n]*?(?:\bhk[a-z]*:|registry::)|"
        r"\bmicrosoft\.win32\.registry\b|\.(?:setvalue|deletevalue|deletesubkey\w*|createsubkey)\(", re.I)),
    ("changes disks or boot settings", re.compile(
        r"\bformat(?:\.com)?\s+[a-z]:|\bformat-volume\b|\bdiskpart\b|\bclear-disk\b|\binitialize-disk\b|"
        r"\b(?:new|remove|resize|set)-partition\b|\bbcdedit\b|\bmountvol\b[^\n]*?/d\b|\bvssadmin\s+delete\b|"
        r"\bwbadmin\s+delete\b|\bmanage-bde\b", re.I)),
    ("removes or disables a service", re.compile(
        r"\bsc(?:\.exe)?[\"']?\s+(?:delete|config)\b|\bremove-service\b|"
        r"\bset-service\b[^\n]*?-startuptype\s+[\"']?disabled", re.I)),
    ("turns off a protection", re.compile(
        r"\bnetsh(?:\.exe)?\s+(?:advfirewall|firewall)\b[^\n]*?\b(?:state\s+off|delete)\b|"
        r"\bset-mppreference\b[^\n]*?-disable|\badd-mppreference\b[^\n]*?-exclusion|"
        r"\bset-netfirewallprofile\b[^\n]*?-enabled\s+[\"']?(?:false|\$false|0)\b|"
        r"\bset-executionpolicy\b(?![^\n]*-scope\s+process)", re.I)),
    ("runs code that can't be read here", re.compile(
        # -e / -ec / -enc / … -encodedcommand followed by a base64 blob (one with a digit, + / or =, so
        # `-ErrorAction SilentlyContinue` isn't one)
        r"\s[-/]e[a-z]*\s+[\"']?(?=[a-z0-9+/=]*[0-9+/=])[a-z0-9+/=]{12,}|\binvoke-expression\b|" + _W + r"iex\b|"
        r"\[scriptblock\]::create|\binvokecommand\.(?:invokescript|newscriptblock)|\.invokescript\(", re.I)),
    ("restarts or shuts down the PC", re.compile(
        r"\bshutdown(?:\.exe)?\b|\brestart-computer\b|\bstop-computer\b|\blogoff(?:\.exe)?\b", re.I)),
    # Live 2026-11-18: an IT run slept the PC through SetSuspendState with no Face ID — twice.
    ("puts the PC to sleep or locks it", re.compile(POWER_ACTION.pattern, re.I)),
]
# The last net: it says it removes something (a word, not "removed" in a message).
_GENERIC = ("removes or disables something", re.compile(
    r"\b(?:delete|remove|uninstall|unregister|erase|wipe|purge)\b|\bdisable-\w+", re.I))
_RUNAS = re.compile(r"\bstart-process\b[^\n]*?-verb\s+[\"']?runas\b", re.I)
_KILL = re.compile(_W + r"(?:stop-process|spps|kill|taskkill(?:\.exe)?)(?=[\s\"']|$)|\.kill\(|"
                   r"\bcall\s+terminate\b|\.terminate\(", re.I)
_UNTIL = r"(?=\s+-\w|[;|)}\n]|$)"
_KILL_LISTS = re.compile(r"-name\s+([^;|)}\n]+?)" + _UNTIL + r"|\bget-process\s+(?:-name\s+)?([^-;|)}\n][^;|)}\n]*?)"
                         + _UNTIL, re.I)
_KILL_ONE = re.compile(r"/im\s+[\"']?([\w.*-]+)|\bname\s*=\s*[\"']?([\w.*-]+)", re.I)
_KILL_IDS = re.compile(r"-id\s+(\d+)|/pid\s+(\d+)", re.I)
_SPLIT = re.compile(r";|\|\||&&|\||\n")


def _names(command: str) -> list:
    raw = []
    for groups in _KILL_LISTS.findall(command):
        raw += [n for g in groups if g for n in g.split(",")]
    raw += [next(g for g in groups if g) for groups in _KILL_ONE.findall(command)]
    out = []
    for name in raw:
        name = name.strip().strip("\"'").lower()
        name = name[:-4] if name.endswith(".exe") else name
        if name and name not in out:
            out.append(name)
    return out


def _kill(command: str, request_text: str):
    if not any(_KILL.search(seg.strip()) for seg in _SPLIT.split(command)) and not _KILL.search(command):
        return None
    ids = [a or b for a, b in _KILL_IDS.findall(command)]
    if ids:
        return f"stops process {ids[0]}, which you didn't name"
    names = _names(command)
    asked = str(request_text or "").lower()
    missing = [n for n in names if n not in asked] if names else ["processes"]
    return f"stops {', '.join(missing)}, which you didn't name" if missing else None


def classify(command: str, request_text: str = "") -> Verdict:
    """Whether ``command`` needs his Face ID (``destructive``) or must never run (``refuse``)."""
    cmd = str(command or "")
    if _RUNAS.search(cmd):
        return Verdict(True, True, "would show a UAC prompt; use an admin step instead")
    segments = [s.strip() for s in _SPLIT.split(cmd) if s.strip()] + [cmd]
    for reason, rule in _RULES:
        if any(rule.search(seg) for seg in segments):
            return Verdict(True, False, reason)
    killed = _kill(cmd, request_text)
    if killed:
        return Verdict(True, False, killed)
    reason, rule = _GENERIC
    if rule.search(cmd):
        return Verdict(True, False, reason)
    return Verdict(False, False, "")
