"""Every store test gets its own registry file, never the real one."""
import pytest


@pytest.fixture
def tmp_registry(tmp_path, monkeypatch):
    import jarvis_registry.store as store_module

    registry = store_module.Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store_module, "shared", lambda: registry)
    return registry
