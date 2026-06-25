"""Tests for agent.coding_dir_suggest.suggest_dirs — the Working Directory /
sync-folder typeahead lister (server side; the jc-client mirrors it).

Each test lists a CONTROLLED sub-directory it fully owns (the shared tmp_path can
hold fixtures injected by conftest), so exact-equality assertions stay stable.
"""
import os

import pytest

from agent.coding_dir_suggest import suggest_dirs


@pytest.fixture
def base(tmp_path):
    b = tmp_path / "base"
    b.mkdir()
    return b


def test_lists_subdirs_of_existing_dir(base):
    (base / "alpha").mkdir()
    (base / "beta").mkdir()
    (base / "afile.txt").write_text("x")
    assert suggest_dirs(str(base) + os.sep) == [
        str(base / "alpha"), str(base / "beta")]


def test_dir_path_without_trailing_sep_drills_in(base):
    (base / "sub").mkdir()
    assert suggest_dirs(str(base)) == [str(base / "sub")]


def test_filters_by_basename_fragment(base):
    (base / "alpha").mkdir()
    (base / "apricot").mkdir()
    (base / "beta").mkdir()
    assert suggest_dirs(str(base / "a")) == [
        str(base / "alpha"), str(base / "apricot")]


def test_empty_lists_home_subdirs(base):
    (base / "h1").mkdir()
    assert str(base / "h1") in suggest_dirs("", home=str(base))


def test_tilde_expands_home_and_folds_results_back(base):
    (base / "proj").mkdir()
    # ~ expands for the lookup, but the result keeps ~-form to match the typed
    # prefix (so a native <datalist> substring-match still shows the option).
    assert suggest_dirs("~/pr", home=str(base)) == ["~/proj"]


def test_absolute_prefix_returns_absolute_paths(base):
    (base / "proj").mkdir()
    # No ~ typed -> absolute results (unchanged).
    assert suggest_dirs(str(base) + os.sep) == [str(base / "proj")]


def test_hidden_excluded_unless_fragment_starts_with_dot(base):
    (base / ".secret").mkdir()
    (base / "visible").mkdir()
    assert str(base / ".secret") not in suggest_dirs(str(base) + os.sep)
    assert suggest_dirs(str(base / ".s")) == [str(base / ".secret")]


def test_dirs_only_not_files(base):
    (base / "d").mkdir()
    (base / "f.txt").write_text("x")
    assert suggest_dirs(str(base) + os.sep) == [str(base / "d")]


def test_missing_dir_returns_empty(base):
    assert suggest_dirs(str(base / "nope") + os.sep) == []


def test_limit_caps_results(base):
    for i in range(60):
        (base / f"d{i:02d}").mkdir()
    assert len(suggest_dirs(str(base) + os.sep, limit=10)) == 10
