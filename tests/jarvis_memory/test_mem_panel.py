import logging
import time

from plugins.memory.jarvis_memory import mem_log
from plugins.memory.jarvis_memory.config import load_config
from plugins.memory.jarvis_memory.status import memory_status
from plugins.memory.jarvis_memory.store import GLOBAL_NS, MemoryStore


def test_mem_log_event_is_captured():
    mem_log.install_handler()
    mem_log.log_event("captured %d fact(s)", 2)
    assert any("captured 2 fact" in r["msg"] for r in mem_log.get_logs(50))


def test_mem_log_captures_package_warnings():
    mem_log.install_handler()
    logging.getLogger("plugins.memory.jarvis_memory").warning("unit-test warning xyzzy")
    logs = mem_log.get_logs(50)
    assert any("xyzzy" in r["msg"] and r["level"] == "WARNING" for r in logs)


def test_events_logger_does_not_propagate_to_file():
    # propagate=False so memory events never reach the gateway file/console.
    mem_log.install_handler()
    assert logging.getLogger(mem_log.EVENTS_LOGGER).propagate is False


def test_memory_status(tmp_path):
    cfg = load_config(str(tmp_path))
    s = MemoryStore(cfg["db_path"], cfg["vault_dir"])
    s.add_chunk(GLOBAL_NS, "Pranav lives in Mountain House", "fact:extracted", time.time(), 1.0, "fact")
    s.close()
    st = memory_status(str(tmp_path))
    assert st["available"] is True
    assert st["count"] == 1
    assert st["embedder"] and "extract_model" in st and "ollama_url" in st
    assert any(n["namespace"] == "global" for n in st["namespaces"])
    assert isinstance(st["ollama_running"], bool)
