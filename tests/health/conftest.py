"""Every store test gets its own registry file, never the real one."""
import sys
from pathlib import Path

import pytest

# The HTTP routes live in the web UI package (`api.*`).
_WEBUI = str(Path(__file__).resolve().parents[2] / "webui")
if _WEBUI not in sys.path:
    sys.path.insert(0, _WEBUI)


@pytest.fixture
def tmp_registry(tmp_path, monkeypatch):
    import jarvis_registry.store as store_module

    registry = store_module.Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store_module, "shared", lambda: registry)
    return registry
