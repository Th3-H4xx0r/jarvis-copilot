import pytest

from plugins.toyota.car import clear_map_cache


@pytest.fixture(autouse=True)
def _fresh_entity_map():
    clear_map_cache()
    yield
    clear_map_cache()
