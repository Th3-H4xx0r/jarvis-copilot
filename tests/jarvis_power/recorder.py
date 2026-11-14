"""Calls made by fake integrations in tests: (integration id, what, process)."""
CALLS: list[tuple] = []
FAIL: set[tuple] = set()      # (id, what) pairs that should raise
