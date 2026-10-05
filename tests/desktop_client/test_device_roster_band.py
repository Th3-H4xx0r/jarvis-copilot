"""The Mac roster knows the HBand smart band, and gives it a symbol until it has a picture."""
from desktop_client.jc_client.device_roster import wearable_kind, wearable_symbol


def test_the_band_is_its_own_kind():
    assert wearable_kind("HBand smart band", "HBand_3C9D") == "band"
    assert wearable_kind("", "Smart band") == "band"


def test_band_is_matched_as_a_word_and_the_rings_keep_their_kinds():
    assert wearable_kind("Colmi R12", "R12_7E04") == "ring"
    assert wearable_kind("X5 smart ring", "X5_7A21") == "x5ring"
    assert wearable_kind("Bandit 3000", "Bandit") == ""


def test_a_wearable_without_a_picture_gets_a_symbol():
    assert wearable_symbol("band") != wearable_symbol("esp32")
    assert wearable_symbol("esp32") == "cpu"
