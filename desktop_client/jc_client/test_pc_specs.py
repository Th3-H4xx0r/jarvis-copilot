"""Specs the PC reads about itself (Windows CIM) for the Specs screen and the model's out-of-date check."""
import json

from jc_client import pc_specs

RAW = {
    "cpu": {"Name": "Intel(R) Core(TM) i7-14700F", "NumberOfCores": 20, "NumberOfLogicalProcessors": 28,
            "MaxClockSpeed": 2100},
    "gpu": [{"Name": "NVIDIA GeForce RTX 5070", "AdapterRAM": 4293918720, "DriverVersion": "32.0.15.8142",
             "CurrentHorizontalResolution": 2560, "CurrentVerticalResolution": 1440, "CurrentRefreshRate": 170}],
    "gpu_mem": [{"name": "NVIDIA GeForce RTX 5070", "bytes": 12884901888}],
    "board": {"Manufacturer": "ASRock", "Product": "B760M-CX"},
    "bios": {"SMBIOSBIOSVersion": "3.10"},
    "mem": [{"Manufacturer": "Team Group Inc.", "PartNumber": "UD5-6000  ", "Capacity": 17179869184,
             "ConfiguredClockSpeed": 6000},
            {"Manufacturer": "Team Group Inc.", "PartNumber": "UD5-6000  ", "Capacity": 17179869184,
             "ConfiguredClockSpeed": 6000}],
    "disk": {"FriendlyName": "WD_BLACK SN770 1TB", "Size": 1000204886016, "MediaType": 4, "BusType": 17},
    "mon": [{"name": "XV272U V3"}],
    "os": {"Caption": "Microsoft Windows 11 Home", "Version": "10.0.26200", "BuildNumber": "26200"},
    "sys": {"Manufacturer": "CyberPowerPC", "Model": "Gamer Supreme"},
}


def _run(raw):
    return lambda command, timeout_s: {"ok": True, "stdout": json.dumps(raw), "stderr": "", "exit_code": 0}


def test_normalises_a_full_read():
    s = pc_specs.read_specs(run=_run(RAW), now=lambda: 1234.0)
    assert s["read_at"] == 1234.0
    assert s["cpu"] == {"name": "Intel(R) Core(TM) i7-14700F", "cores": 20, "threads": 28, "max_mhz": 2100}
    assert s["gpus"][0]["name"] == "NVIDIA GeForce RTX 5070" and s["gpus"][0]["driver"] == "32.0.15.8142"
    assert s["board"] == {"maker": "ASRock", "product": "B760M-CX", "bios": "3.10"}
    assert s["memory"]["total_mb"] == 32768 and len(s["memory"]["modules"]) == 2
    assert s["memory"]["modules"][0] == {"maker": "Team Group Inc.", "part": "UD5-6000", "size_mb": 16384, "mhz": 6000}
    assert s["storage"] == [{"model": "WD_BLACK SN770 1TB", "size_gb": 1000, "kind": "NVMe SSD"}]
    assert s["displays"][0] == {"name": "XV272U V3", "width": 2560, "height": 1440, "hz": 170}
    assert s["os"] == {"name": "Microsoft Windows 11 Home", "version": "10.0.26200", "build": "26200"}
    assert s["system"] == {"maker": "CyberPowerPC", "model": "Gamer Supreme"}


def test_vram_comes_from_the_driver_when_adapter_ram_wraps():
    s = pc_specs.read_specs(run=_run(RAW), now=lambda: 1.0)
    assert s["gpus"][0]["vram_mb"] == 12288


def test_missing_classes_give_empty_values_never_raise():
    s = pc_specs.read_specs(run=_run({"cpu": None}), now=lambda: 1.0)
    assert s["gpus"] == [] and s["storage"] == [] and s["displays"] == [] and s["memory"]["modules"] == []
    assert s["cpu"]["name"] == ""


def test_a_failed_powershell_run_gives_none():
    assert pc_specs.read_specs(run=lambda c, t: {"ok": True, "stdout": "", "stderr": "boom", "exit_code": 1},
                               now=lambda: 1.0) is None


def test_fingerprint_ignores_read_time():
    a = pc_specs.read_specs(run=_run(RAW), now=lambda: 1.0)
    b = pc_specs.read_specs(run=_run(RAW), now=lambda: 2.0)
    assert pc_specs.fingerprint(a) == pc_specs.fingerprint(b)
    raw2 = dict(RAW, gpu=[dict(RAW["gpu"][0], Name="NVIDIA GeForce RTX 5080")])
    assert pc_specs.fingerprint(pc_specs.read_specs(run=_run(raw2), now=lambda: 1.0)) != pc_specs.fingerprint(a)


def test_skill_registers_under_its_contract_name():
    from jc_client import skills as registry
    pc_specs.register()
    assert "pc_specs_read" in registry._REGISTRY


def test_reporter_sends_once_then_only_on_change_and_retries_when_offline():
    sent, ok = [], {"v": False}
    reads = {"raw": RAW}

    def send(frame):
        if ok["v"]:
            sent.append(frame)
        return ok["v"]

    r = pc_specs.SpecsReporter(send, reader=lambda: pc_specs.read_specs(run=_run(reads["raw"]), now=lambda: 1.0))
    assert r.run_once() is False                 # offline: nothing went, try again later
    ok["v"] = True
    assert r.run_once() is True and sent[-1]["name"] == "pc_specs"
    assert r.run_once() is False                 # unchanged: not resent
    reads["raw"] = dict(RAW, board={"Manufacturer": "ASRock", "Product": "Z790"})
    assert r.run_once() is True and sent[-1]["data"]["board"]["product"] == "Z790"
