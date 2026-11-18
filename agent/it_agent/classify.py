"""Which PC commands need his Face ID: deletes, uninstalls, registry writes, disk/boot changes, service
removal, stopping processes he didn't name, turning off protections, unreadable code, power. A false positive
only costs a Face ID prompt; a miss could cost his files — so every segment of a command is checked."""
from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass
class Verdict:
    destructive: bool
    refuse: bool
    reason: str


_W = r"(?:^|(?<=[\s(;{|&]))"   # a command word starts the segment or follows a separator
_RULES = [
    ("deletes files", re.compile(
        _W + r"(?:remove-item|ri|rm|del|erase|rd|rmdir|clear-content|clear-recyclebin)(?=\s|$)|\.delete\(|"
        r"\[(?:system\.)?io\.(?:file|directory)\]::delete|\bcipher(?:\.exe)?\s+/w|\bgit\s+clean\b|"
        r"\bgit\s+reset\s+--hard\b", re.I)),
    ("uninstalls software", re.compile(
        r"\bwinget(?:\.exe)?\s+(?:uninstall|remove)\b|\buninstall-package\b|\bremove-appxpackage\b|"
        r"\bmsiexec(?:\.exe)?\b[^\n]*?/x\b|\bchoco(?:\.exe)?\s+uninstall\b|\bscoop\s+uninstall\b|"
        r"\bdisable-windowsoptionalfeature\b|\bdism(?:\.exe)?\b[^\n]*?/disable-feature|"
        r"\bwsl(?:\.exe)?\s+--(?:unregister|uninstall)\b", re.I)),
    ("changes the registry", re.compile(
        r"\breg(?:\.exe)?\s+(?:add|delete|import|restore|load|unload|copy)\b|\bregedit(?:\.exe)?\s+/s\b|"
        r"\b(?:set|new|remove|rename)-itemproperty\b|\b(?:new|remove)-item\b[^\n]*?(?:\bhk[a-z]*:|registry::)", re.I)),
    ("changes disks or boot settings", re.compile(
        r"\bformat(?:\.com)?\s+[a-z]:|\bformat-volume\b|\bdiskpart\b|\bclear-disk\b|\binitialize-disk\b|"
        r"\b(?:new|remove|resize|set)-partition\b|\bbcdedit\b|\bmountvol\b[^\n]*?/d\b|\bvssadmin\s+delete\b|"
        r"\bwbadmin\s+delete\b|\bmanage-bde\b", re.I)),
    ("removes or disables a service", re.compile(
        r"\bsc(?:\.exe)?\s+(?:delete|config)\b|\bremove-service\b|\bset-service\b[^\n]*?-startuptype\s+disabled",
        re.I)),
    ("turns off a protection", re.compile(
        r"\bnetsh(?:\.exe)?\s+advfirewall\b[^\n]*?\bstate\s+off\b|\bset-mppreference\b[^\n]*?-disable", re.I)),
    ("runs code that can't be read here", re.compile(
        r"\s-(?:encodedcommand|enc|e)\s+[a-z0-9+/=]{8,}|\binvoke-expression\b|" + _W + r"iex\b|"
        r"\[scriptblock\]::create", re.I)),
    ("restarts or shuts down the PC", re.compile(
        r"\bshutdown(?:\.exe)?\b|\brestart-computer\b|\bstop-computer\b|\blogoff(?:\.exe)?\b", re.I)),
]
_RUNAS = re.compile(r"\bstart-process\b[^\n]*?-verb\s+runas\b", re.I)
_KILL = re.compile(_W + r"(?:stop-process|spps|kill|taskkill(?:\.exe)?)(?=\s|$)", re.I)
_KILL_NAMES = re.compile(r"-name\s+[\"']?([\w.*-]+)|/im\s+[\"']?([\w.*-]+)|\bget-process\s+(?:-name\s+)?[\"']?([\w.*-]+)",
                         re.I)
_KILL_IDS = re.compile(r"-id\s+(\d+)|/pid\s+(\d+)", re.I)
_SPLIT = re.compile(r";|\|\||&&|\||\n")


def _kill(command: str, request_text: str):
    if not any(_KILL.search(seg.strip()) for seg in _SPLIT.split(command)):
        return None
    ids = [a or b for a, b in _KILL_IDS.findall(command)]
    if ids:
        return f"stops process {ids[0]}, which you didn't name"
    names = []
    for groups in _KILL_NAMES.findall(command):
        name = next(g for g in groups if g).lower()
        name = name[:-4] if name.endswith(".exe") else name
        if name and name not in names:
            names.append(name)
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
    return Verdict(False, False, "")
