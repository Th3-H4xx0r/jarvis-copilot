"""The Mac's answer to the server's folder typeahead (coding_dir_list_get)."""
import os

from jc_client import dir_list


def test_lists_subdirs_of_a_folder(tmp_path):
    (tmp_path / "alpha").mkdir()
    (tmp_path / "beta").mkdir()
    (tmp_path / "f.txt").write_text("x")
    sent = []
    dir_list.handle_frame({"type": dir_list.FRAME, "req_id": "d1",
                           "path": str(tmp_path) + os.sep}, sent.append, home=str(tmp_path))
    assert sent == [{"type": dir_list.REPLY, "req_id": "d1", "ok": True,
                     "dirs": [str(tmp_path / "alpha"), str(tmp_path / "beta")]}]


def test_empty_path_lists_home(tmp_path):
    (tmp_path / "proj").mkdir()
    sent = []
    dir_list.handle_frame({"type": dir_list.FRAME, "req_id": "d2", "path": ""},
                          sent.append, home=str(tmp_path))
    assert str(tmp_path / "proj") in sent[0]["dirs"]


def test_partial_name_matches_siblings_and_hides_dot_dirs(tmp_path):
    for name in ("code", "coding", "docs", ".config"):
        (tmp_path / name).mkdir()
    assert dir_list.suggest_dirs(str(tmp_path / "co"), home=str(tmp_path)) == [
        str(tmp_path / "code"), str(tmp_path / "coding")]
    assert dir_list.suggest_dirs(str(tmp_path / ".c"), home=str(tmp_path)) == [
        str(tmp_path / ".config")]


def test_tilde_prefix_folds_back_to_tilde(tmp_path):
    (tmp_path / "proj").mkdir()
    assert dir_list.suggest_dirs("~/", home=str(tmp_path)) == ["~/proj"]


def test_no_req_id_no_reply_and_send_failure_is_swallowed(tmp_path):
    sent = []
    dir_list.handle_frame({"type": dir_list.FRAME, "path": ""}, sent.append, home=str(tmp_path))
    assert sent == []

    def boom(_frame):
        raise OSError("socket closed")

    dir_list.handle_frame({"type": dir_list.FRAME, "req_id": "x", "path": ""}, boom,
                          home=str(tmp_path))
