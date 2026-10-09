"""HAClient against a local aiohttp server standing in for Home Assistant (no network)."""
import asyncio

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from plugins.toyota.ha import HAClient, HAError, HAUnreachable

TOKEN = "t0k"


def app():
    async def state(request):
        if request.headers.get("Authorization") != f"Bearer {TOKEN}":
            return web.json_response({"message": "Unauthorized"}, status=401)
        if request.match_info["eid"] == "sensor.gone":
            return web.json_response({"message": "Entity not found."}, status=404)
        return web.json_response({"entity_id": request.match_info["eid"], "state": "1"})

    async def service(request):
        return web.json_response({"message": "Remote Connect isn't active"}, status=500)

    async def ws(request):
        sock = web.WebSocketResponse()
        await sock.prepare(request)
        await sock.send_json({"type": "auth_required"})
        auth = await sock.receive_json()
        await sock.send_json({"type": "auth_ok" if auth.get("access_token") == TOKEN else "auth_invalid"})
        msg = await sock.receive_json()
        await sock.send_json({"id": msg["id"], "type": "result", "success": True,
                              "result": [{"entity_id": "lock.camry", "platform": "toyota_na"}]})
        await sock.close()
        return sock

    a = web.Application()
    a.router.add_get("/api/states/{eid}", state)
    a.router.add_post("/api/services/toyota_na/door_lock", service)
    a.router.add_get("/api/websocket", ws)
    return a


def with_server(test):
    async def go():
        server = TestServer(app())
        await server.start_server()
        try:
            await test(HAClient(str(server.make_url("")), TOKEN))
        finally:
            await server.close()
    asyncio.run(go())


def test_states_skip_entities_home_assistant_does_not_have():
    async def test(ha):
        assert await ha.states(["sensor.a", "sensor.gone"]) == {"sensor.a": {"entity_id": "sensor.a", "state": "1"}}
    with_server(test)


def test_errors_carry_home_assistants_message_and_status():
    async def test(ha):
        with pytest.raises(HAError) as err:
            await ha.post("/api/services/toyota_na/door_lock", {"vehicle": "d"})
        assert str(err.value) == "Remote Connect isn't active" and err.value.status == 500
    with_server(test)


def test_entity_registry_over_the_websocket():
    async def test(ha):
        assert await ha.entity_registry() == [{"entity_id": "lock.camry", "platform": "toyota_na"}]
    with_server(test)


def test_nothing_listening_or_not_configured_is_unreachable():
    with pytest.raises(HAUnreachable):
        asyncio.run(HAClient("http://127.0.0.1:9", TOKEN).get("/api/"))
    with pytest.raises(HAUnreachable, match="HASS_URL"):
        asyncio.run(HAClient("", "").get("/api/"))
