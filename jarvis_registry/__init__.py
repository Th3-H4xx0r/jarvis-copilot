"""The central registry: one store for everything Jarvis integrations keep."""

from jarvis_registry.store import Registry, RegistryError, Space, UnknownSpace

__all__ = ["Registry", "RegistryError", "Space", "UnknownSpace"]
