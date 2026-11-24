"""A frozen webui (live 2026-11-23: silent from 23:52 until a reboot) must be diagnosable: kill -USR1 <pid>
prints every thread's stack to the journal."""
import faulthandler
import signal
import sys

import pytest


@pytest.mark.skipif(sys.platform == "win32", reason="no SIGUSR1 on Windows")
def test_usr1_dumps_every_threads_stack():
    import server
    server._register_stack_dump()
    assert faulthandler.unregister(signal.SIGUSR1) is True
