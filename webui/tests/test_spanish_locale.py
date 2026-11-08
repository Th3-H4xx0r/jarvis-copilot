from pathlib import Path
import re


REPO = Path(__file__).resolve().parent.parent


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_spanish_locale_block_exists():
    src = read(REPO / "static" / "i18n.js")
    assert "\n  es: {" in src
    assert "_label: 'Español'" in src
    assert "_speech: 'es-ES'" in src


def test_spanish_locale_includes_representative_translations():
    src = read(REPO / "static" / "i18n.js")
    expected = [
        "settings_title: 'Configuración'",
        "login_title: 'Iniciar sesión'",
        "approval_heading: 'Se requiere aprobación'",
        "tab_tasks: 'Tareas'",
        "tab_skills: 'Habilidades'",
        "tab_memory: 'Memoria'",
    ]
    for entry in expected:
        assert entry in src

