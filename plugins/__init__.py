"""JarvisCopilot plugins package.

Also holds the loader shared by the single-instance plugin categories that
live outside the general PluginManager (memory providers, context engines).
"""

from __future__ import annotations

import importlib.util
import logging
import sys
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


def plugin_description(plugin_dir: Path) -> str:
    """The ``description`` from ``plugin_dir/plugin.yaml`` ("" when absent)."""
    yaml_file = plugin_dir / "plugin.yaml"
    if not yaml_file.exists():
        return ""
    try:
        import yaml
        with open(yaml_file, encoding="utf-8-sig") as f:
            meta = yaml.safe_load(f) or {}
        return meta.get("description", "") or ""
    except Exception:
        logger.debug("Could not read %s", yaml_file, exc_info=True)
        return ""


class _Collector:
    """Fake plugin context: keeps what ``register_method`` receives and
    ignores every other ``register_*`` call."""

    def __init__(self, register_method: str):
        self.instance = None
        setattr(self, register_method, self._capture)

    def _capture(self, obj) -> None:
        self.instance = obj

    def __getattr__(self, name: str):
        if name.startswith("register_"):
            return lambda *args, **kwargs: None
        raise AttributeError(name)


def load_plugin_instance(plugin_dir: Path, module_name: str, register_method: str, base_cls: type) -> Optional[Any]:
    """Import the plugin package in ``plugin_dir`` as ``module_name`` and
    return the instance it provides.

    The plugin either calls ``ctx.<register_method>(instance)`` from its
    ``register(ctx)`` function, or defines a top-level ``base_cls`` subclass
    that is instantiated.  Sibling ``*.py`` files are registered as
    submodules first so the plugin's relative imports resolve.
    """
    init_file = plugin_dir / "__init__.py"
    if not init_file.exists():
        return None

    mod = sys.modules.get(module_name)
    if mod is None:
        spec = importlib.util.spec_from_file_location(
            module_name, str(init_file),
            submodule_search_locations=[str(plugin_dir)],
        )
        if not spec:
            return None
        mod = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = mod

        for sub_file in plugin_dir.glob("*.py"):
            if sub_file.name == "__init__.py":
                continue
            full_sub_name = f"{module_name}.{sub_file.stem}"
            if full_sub_name in sys.modules:
                continue
            sub_spec = importlib.util.spec_from_file_location(full_sub_name, str(sub_file))
            if sub_spec:
                sub_mod = importlib.util.module_from_spec(sub_spec)
                sys.modules[full_sub_name] = sub_mod
                try:
                    sub_spec.loader.exec_module(sub_mod)
                except Exception as e:
                    logger.debug("Failed to load submodule %s: %s", full_sub_name, e)

        try:
            spec.loader.exec_module(mod)
        except Exception as e:
            logger.debug("Failed to exec_module %s: %s", module_name, e)
            sys.modules.pop(module_name, None)
            return None

    if hasattr(mod, "register"):
        collector = _Collector(register_method)
        try:
            mod.register(collector)
            if collector.instance:
                return collector.instance
        except Exception as e:
            logger.debug("register() failed for %s: %s", plugin_dir.name, e)

    for attr_name in dir(mod):
        attr = getattr(mod, attr_name, None)
        if isinstance(attr, type) and issubclass(attr, base_cls) and attr is not base_cls:
            try:
                return attr()
            except Exception:
                logger.debug("Could not instantiate %s.%s", module_name, attr_name, exc_info=True)
    return None
