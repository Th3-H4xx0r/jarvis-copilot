"""The Mac roster tells the two rings apart, so each gets its own picture."""
from desktop_client.jc_client.device_roster import wearable_kind


def test_the_x5_is_its_own_kind():
    assert wearable_kind("X5 smart ring", "X5_7A21") == "x5ring"


def test_the_r12_is_still_the_ring():
    assert wearable_kind("Colmi R12", "R12_7E04") == "ring"
    assert wearable_kind("", "Smart ring") == "ring"
