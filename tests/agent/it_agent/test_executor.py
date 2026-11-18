"""The executor: terminal steps unelevated, destructive ones only after Face ID (still unelevated), admin
steps elevated after Face ID; checks evaluated by code, retried once after settling."""
from agent.it_agent.executor import needs_face_id, run_check, run_step
from agent.it_agent.model import Check, Deps, Run, ScreenResult, ShellResult, Step


class Rec:
    def __init__(self):
        self.shells, self.admins, self.approved, self.slept, self.screens = [], [], [], [], []
        self.shell_results, self.screen_text = [], ""

    def deps(self):
        nothing = lambda *a, **k: None  # noqa: E731

        def shell(c, t):
            self.shells.append((c, t))
            return self.shell_results.pop(0) if self.shell_results else ShellResult("ran", 0, "ok")

        return Deps(ask=nothing, search=lambda q: [{"url": "https://u/1", "title": "a"}, {"url": "https://u/2"}],
                    extract=lambda urls: [{"url": u, "content": f"text of {u}"} for u in urls],
                    shell=shell,
                    admin=lambda c, w, t: self.admins.append((c, w, t)) or ShellResult("ran", 0, "admin ok", routed="admin"),
                    screen=lambda g: self.screens.append(g) or ScreenResult(True, "done"),
                    read_screen=lambda app: self.screen_text, online=lambda: True, signed_in=lambda: True,
                    wake=nothing, notify=nothing, progress=nothing, should_stop=lambda: False,
                    sleep=lambda s: self.slept.append(s),
                    approved=lambda c, w, t: self.approved.append((c, w, t)) or ShellResult("ran", 0, "removed", routed="approved"))


def _run(screen=False):
    return Run(goal="install docker", request_text="install docker desktop on my pc", device_id="d",
               device_name="PC", screen_allowed=screen)


def test_shell_step_runs_unelevated():
    rec = Rec()
    r = run_step(Step("shell", "winget install -e --id Docker.DockerDesktop"), _run(), rec.deps())
    assert r.ok and rec.shells and not rec.admins and not rec.approved


def test_destructive_shell_step_goes_to_face_id_but_stays_unelevated():
    rec = Rec()
    r = run_step(Step("shell", "winget remove x", why="clean up"), _run(), rec.deps())
    assert r.ok and not rec.admins and not rec.shells
    assert rec.approved[0][0] == "winget remove x" and "uninstalls software" in rec.approved[0][1]


def test_admin_step_goes_elevated_after_face_id():
    rec = Rec()
    run_step(Step("admin", "wsl --install --no-distribution", why="enable WSL2"), _run(), rec.deps())
    assert rec.admins[0][:2] == ("wsl --install --no-distribution", "enable WSL2")


def test_refused_step_never_runs():
    rec = Rec()
    r = run_step(Step("shell", "Start-Process powershell -Verb RunAs"), _run(), rec.deps())
    assert r.status == "refused" and not rec.shells and not rec.admins and not rec.approved


def test_nonzero_exit_fails_unless_ok_code():
    rec = Rec()
    rec.shell_results = [ShellResult("ran", 1, "boom"), ShellResult("ran", -1978335189, "already installed")]
    assert not run_step(Step("shell", "winget install x"), _run(), rec.deps()).ok
    assert run_step(Step("shell", "winget install x", ok_exit_codes=[0, -1978335189]), _run(), rec.deps()).ok


def test_reboot_exit_codes_mark_restart_needed():
    rec = Rec()
    rec.shell_results = [ShellResult("ran", 3010, "restart required")]
    r = run_step(Step("shell", "winget install x"), _run(), rec.deps())
    assert r.ok and r.restart_needed


def test_needs_face_id():
    assert needs_face_id(Step("admin", "dism /online"), "") and needs_face_id(Step("shell", "rm -r x"), "")
    assert not needs_face_id(Step("shell", "docker --version"), "")


def test_check_evaluated_mechanically():
    rec = Rec()
    rec.shell_results = [ShellResult("ran", 0, "something else")] * 2
    r = run_check(Check("shell", "docker --version", contains="Docker version"), rec.deps(), 0)
    assert not r.passed and r.detail == 'output lacks "Docker version"'


def test_check_that_times_out_fails():
    rec = Rec()
    rec.shell_results = [ShellResult("timeout")] * 2
    r = run_check(Check("shell", "docker run hello-world", timeout_s=120), rec.deps(), 0)
    assert not r.passed and r.detail == "timed out after 120 s"


def test_check_retried_once_after_settle():
    rec = Rec()
    rec.shell_results = [ShellResult("ran", 1, "not yet"), ShellResult("ran", 0, "Docker version 27")]
    r = run_check(Check("shell", "docker --version", contains="Docker version"), rec.deps(), 15)
    assert r.passed and rec.slept == [15]


def test_screen_check_reads_text():
    rec = Rec()
    rec.screen_text = "Docker Desktop — Engine running"
    assert run_check(Check("screen", app="Docker Desktop", contains="Engine running"), rec.deps(), 0).passed


def test_screen_step_blocked_when_gate_closed():
    rec = Rec()
    r = run_step(Step("screen", goal="click Accept"), _run(screen=False), rec.deps())
    assert r.status == "refused" and r.detail == "Screen steps need you to ask for your PC in your own words."
    assert run_step(Step("screen", goal="click Accept"), _run(screen=True), rec.deps()).ok
