"""What the PC reads about its own hardware (Windows CIM) for the Specs screen and the model's
out-of-date check. One PowerShell run; sent up as a pc_specs event when it changes."""
from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)

READ_EVERY_S = 6 * 3600
RETRY_S = 30.0

PS = r"""
$ErrorActionPreference = 'SilentlyContinue'
$gpuMem = @()
Get-ChildItem 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  if ($p.'HardwareInformation.qwMemorySize') { $gpuMem += @{ name = $p.DriverDesc; bytes = [int64]$p.'HardwareInformation.qwMemorySize' } }
}
$mon = @(Get-CimInstance -Namespace root\wmi WmiMonitorID | ForEach-Object {
  @{ name = (($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '') } })
@{
  cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
  gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name, AdapterRAM, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate)
  gpu_mem = $gpuMem
  board = Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product
  bios = Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion
  mem = @(Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, Capacity, ConfiguredClockSpeed)
  disk = @(Get-CimInstance -Namespace root\Microsoft\Windows\Storage MSFT_PhysicalDisk | Select-Object FriendlyName, Size, MediaType, BusType)
  mon = $mon
  os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
  sys = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model
} | ConvertTo-Json -Depth 4 -Compress
"""


def _list(v: Any) -> list:
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def _obj(v: Any) -> dict:
    if isinstance(v, list):
        v = v[0] if v else None
    return v if isinstance(v, dict) else {}


def _s(v: Any) -> str:
    return str(v).strip() if v is not None else ""


def _i(v: Any) -> Optional[int]:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _disk_kind(d: dict) -> str:
    if _i(d.get("BusType")) == 17:
        return "NVMe SSD"
    return {3: "HDD", 4: "SSD"}.get(_i(d.get("MediaType")) or 0, "Drive")


def normalise(raw: dict, read_at: float) -> dict:
    cpu = _obj(raw.get("cpu"))
    vram = {_s(m.get("name")): _i(m.get("bytes")) for m in _list(raw.get("gpu_mem")) if isinstance(m, dict)}
    gpus_raw = [g for g in _list(raw.get("gpu")) if isinstance(g, dict)]
    gpus = []
    for g in gpus_raw:
        name = _s(g.get("Name"))
        b = vram.get(name) or _i(g.get("AdapterRAM")) or 0
        gpus.append({"name": name, "vram_mb": b // (1024 * 1024) if b else None, "driver": _s(g.get("DriverVersion"))})
    modules = [{"maker": _s(m.get("Manufacturer")), "part": _s(m.get("PartNumber")),
                "size_mb": (_i(m.get("Capacity")) or 0) // (1024 * 1024), "mhz": _i(m.get("ConfiguredClockSpeed"))}
               for m in _list(raw.get("mem")) if isinstance(m, dict)]
    first = gpus_raw[0] if gpus_raw else {}
    displays = []
    for k, m in enumerate(m for m in _list(raw.get("mon")) if isinstance(m, dict)):
        displays.append({"name": _s(m.get("name")),
                         "width": _i(first.get("CurrentHorizontalResolution")) if k == 0 else None,
                         "height": _i(first.get("CurrentVerticalResolution")) if k == 0 else None,
                         "hz": _i(first.get("CurrentRefreshRate")) if k == 0 else None})
    board, bios, osr, sysr = (_obj(raw.get(k)) for k in ("board", "bios", "os", "sys"))
    return {
        "read_at": read_at,
        "cpu": {"name": _s(cpu.get("Name")), "cores": _i(cpu.get("NumberOfCores")),
                "threads": _i(cpu.get("NumberOfLogicalProcessors")), "max_mhz": _i(cpu.get("MaxClockSpeed"))},
        "gpus": gpus,
        "board": {"maker": _s(board.get("Manufacturer")), "product": _s(board.get("Product")),
                  "bios": _s(bios.get("SMBIOSBIOSVersion"))},
        "memory": {"total_mb": sum(m["size_mb"] for m in modules), "modules": modules},
        "storage": [{"model": _s(d.get("FriendlyName")), "size_gb": round((_i(d.get("Size")) or 0) / 1e9),
                     "kind": _disk_kind(d)} for d in _list(raw.get("disk")) if isinstance(d, dict)],
        "displays": displays,
        "os": {"name": _s(osr.get("Caption")), "version": _s(osr.get("Version")), "build": _s(osr.get("BuildNumber"))},
        "system": {"maker": _s(sysr.get("Manufacturer")), "model": _s(sysr.get("Model"))},
    }


def _default_run(command: str, timeout_s: int) -> dict:
    from jc_client.skills.pc_it import run_powershell
    return run_powershell(command, timeout_s)


def read_specs(run: Callable[[str, int], dict] = _default_run, now: Callable[[], float] = time.time) -> Optional[dict]:
    """The PC's specs, or None when PowerShell failed (never raises)."""
    try:
        res = run(PS, 60)
        if res.get("exit_code") not in (0, None) or not (res.get("stdout") or "").strip():
            log.warning("specs read failed: %s", (res.get("stderr") or "")[:300])
            return None
        return normalise(json.loads(res["stdout"]), now())
    except Exception:  # noqa: BLE001
        log.warning("specs read failed", exc_info=True)
        return None


def fingerprint(specs: Optional[dict]) -> str:
    body = {k: v for k, v in (specs or {}).items() if k != "read_at"}
    return hashlib.sha1(json.dumps(body, sort_keys=True).encode()).hexdigest()


class SpecsReporter:
    """Sends the specs up once, then again only when they change; retries while offline."""

    def __init__(self, send_up: Callable[[dict], bool], reader: Callable[[], Optional[dict]] = read_specs) -> None:
        self._send_up = send_up
        self._reader = reader
        self._sent: Optional[str] = None
        self._stop = threading.Event()

    def run_once(self, force: bool = False) -> bool:
        specs = self._reader()
        if not specs:
            return False
        fp = fingerprint(specs)
        if fp == self._sent and not force:
            return False
        if self._send_up({"type": "event", "name": "pc_specs", "data": specs}):
            self._sent = fp
            return True
        return False

    def start(self) -> None:
        def loop():
            wait = 5.0
            while not self._stop.wait(wait):
                self.run_once()
                wait = READ_EVERY_S if self._sent else RETRY_S

        threading.Thread(target=loop, name="pc-specs", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()


_reporter: Optional[SpecsReporter] = None


def pc_specs_read() -> dict:
    """Server-only skill: read now (and resend if changed)."""
    specs = read_specs()
    if specs is None:
        return {"ok": False, "error": "Couldn't read the PC's specs"}
    if _reporter is not None:
        _reporter.run_once(force=True)
    return {"ok": True, "specs": specs}


def set_reporter(reporter: Optional[SpecsReporter]) -> None:
    global _reporter
    _reporter = reporter


def register() -> None:
    from jc_client.skills import skill
    skill("pc_specs_read", "Server-only: read this PC's hardware specs now.", {"type": "object"})(pc_specs_read)
