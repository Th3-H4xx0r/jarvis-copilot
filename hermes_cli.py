"""Back-compat alias — ``hermes_cli`` is now ``jarviscopilot_cli``.

Third-party code (plugins, agents-from-another-fork, anything outside
this repo) may still ``import hermes_cli`` or ``from hermes_cli.X import
Y``. This module aliases the legacy name to the renamed package at
import time via ``sys.modules`` so those imports keep working.

How it works: when Python evaluates ``import hermes_cli.main``, it
first loads this file (``hermes_cli.py``). The file imports the real
package as ``jarviscopilot_cli`` and rebinds ``sys.modules['hermes_cli']``
to that package object. The submodule lookup that follows then uses
the package's ``__path__``, which points at the real
``jarviscopilot_cli/`` directory, so ``hermes_cli.main`` resolves to
``jarviscopilot_cli/main.py`` and is also registered under both names
in ``sys.modules``.

No new code should use the ``hermes_cli`` name — write ``import
jarviscopilot_cli`` directly. This shim exists only to keep prior
checkouts / pinned vendors compiling during the rebrand window.
"""
from __future__ import annotations

import importlib as _importlib
import pkgutil as _pkgutil
import sys as _sys

# Make sure the real package exists before aliasing.
import jarviscopilot_cli as _real  # noqa: F401

# Replace this module in sys.modules with the real package so submodule
# imports (``hermes_cli.X``) resolve via jarviscopilot_cli's __path__.
_sys.modules[__name__] = _real

# Pre-load every submodule and alias it under the legacy name. Without
# this, ``from hermes_cli.X import Y`` would create a *second* module
# object for ``hermes_cli.X`` distinct from ``jarviscopilot_cli.X``,
# causing module-level state (caches, locks, singletons) to diverge
# between the two paths. With the alias in place, both names point at
# the same module object.
for _info in _pkgutil.iter_modules(_real.__path__):
    _full = f"{_real.__name__}.{_info.name}"
    try:
        _sub = _importlib.import_module(_full)
    except BaseException:
        # Some submodules legitimately fail at import time on the
        # current platform (e.g. gateway_windows on Linux) or when
        # heavy optional deps are missing (web_server hard-exits if
        # fastapi isn't installed). Skip them — they aren't reachable
        # via the legacy name either, since they'd fail the same way
        # under jarviscopilot_cli. BaseException catches SystemExit /
        # KeyboardInterrupt from over-eager hard-exits at module
        # import time.
        continue
    _sys.modules[f"{__name__}.{_info.name}"] = _sub
