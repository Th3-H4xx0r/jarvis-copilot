"""Shared fixtures for the Power integrations framework tests."""
from __future__ import annotations

import json
import shutil
import sys
import textwrap
from pathlib import Path

import pytest

from jarvis_power import discovery

REPO = Path(__file__).resolve().parents[2]
TEMPLATE = REPO / "jarvis_power" / "integrations" / "_template"


@pytest.fixture()
def fake_pkg(tmp_path, monkeypatch):
    """A throwaway integrations package. Call it with {dir_name: source or None}.

    ``None`` copies the real ``_template`` into that directory. A dict value is
    ``{"source": str, "ui": dict}`` when the integration needs a ``ui.json``.
    Returns the package's dotted name, already active for discovery.
    """
    root = tmp_path / "fakepower_root"
    pkg = root / "fakepower_integrations"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text("")
    monkeypatch.syspath_prepend(str(root))

    def build(modules: dict):
        for name, spec in modules.items():
            target = pkg / name
            if target.exists():
                shutil.rmtree(target)
            if spec is None:
                shutil.copytree(TEMPLATE, target)
                continue
            target.mkdir()
            if isinstance(spec, dict):
                source, ui = spec["source"], spec.get("ui")
            else:
                source, ui = spec, None
            (target / "__init__.py").write_text(textwrap.dedent(source))
            if ui is not None:
                (target / "ui.json").write_text(json.dumps(ui))
        for mod in [m for m in sys.modules if m.startswith("fakepower_integrations")]:
            del sys.modules[mod]
        monkeypatch.setattr(discovery, "PACKAGE", "fakepower_integrations")
        discovery.reset()
        return "fakepower_integrations"

    yield build
    discovery.reset()


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    """A fresh registry the framework reads and writes."""
    import jarvis_registry.store as store
    from jarvis_registry import Registry

    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    from jarvis_power import state
    state.reset_cache()
    yield r
    state.reset_cache()
    r.close()


SIMPLE = '''
from jarvis_power import PowerIntegration

class Simple(PowerIntegration):
    id = "{id}"
    name = "{name}"
    icon = "bolt"
    summary = "A test integration."
    default_enabled = {default}
    {extra}
'''


def simple(id="alpha", name="Alpha", default=True, extra=""):
    return SIMPLE.format(id=id, name=name, default=default, extra=extra)
