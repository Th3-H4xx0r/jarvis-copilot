"""Tests for issue #538 — MCP server listing API (secrets masked)."""
import json, pytest
from unittest.mock import patch, MagicMock, call
from api.routes import (
    _handle_mcp_servers_list,
    _mask_secrets,
    _parse_mcp_enabled,
    _server_summary,
)


def _make_handler():
    h = MagicMock()
    h.path = '/api/mcp/servers'
    h.command = 'GET'
    return h


def _json_payload(handler):
    body = handler.wfile.write.call_args[0][0]
    return json.loads(body.decode('utf-8'))


SAMPLE_MCP = {
    "searxng": {
        "command": "mcp-searxng",
        "args": ["--port", "8888"],
        "timeout": 120
    },
    "web-reader": {
        "url": "http://localhost:3001/mcp",
        "timeout": 60,
        "headers": {"Authorization": "Bearer secret123"}
    }
}


class TestMcpList:
    """GET /api/mcp/servers — list with masked secrets."""

    @patch('api.routes.get_config')
    def test_returns_servers_list(self, mock_cfg):
        mock_cfg.return_value = {'mcp_servers': SAMPLE_MCP}
        h = _make_handler()
        _handle_mcp_servers_list(h)
        assert h.send_response.called
        status = h.send_response.call_args[0][0]
        assert status == 200

    @patch('api.routes.get_config')
    def test_empty_config(self, mock_cfg):
        mock_cfg.return_value = {}
        h = _make_handler()
        _handle_mcp_servers_list(h)
        assert h.send_response.called
        status = h.send_response.call_args[0][0]
        assert status == 200
        payload = _json_payload(h)
        assert payload['servers'] == []
        assert payload['toggle_supported'] is False
        assert payload['reload_required'] is True

    @patch('api.routes._mcp_runtime_status_by_name')
    @patch('api.routes.get_config')
    def test_list_payload_includes_status_tool_counts_and_safe_invalid_config(self, mock_cfg, mock_runtime):
        mock_cfg.return_value = {
            'mcp_servers': {
                'searxng': {'command': 'mcp-searxng', 'args': ['--port', '8888']},
                'web-reader': {
                    'url': 'http://localhost:3001/mcp',
                    'headers': {'Authorization': 'Bearer secret123'},
                },
                'disabled': {'command': 'disabled-cmd', 'enabled': 0},
                'broken': 'not-a-dict',
            }
        }
        mock_runtime.return_value = {
            'searxng': {'connected': True, 'tools': 3},
            'web-reader': {'connected': False, 'tools': 0},
        }
        h = _make_handler()
        _handle_mcp_servers_list(h)
        payload = _json_payload(h)
        by_name = {s['name']: s for s in payload['servers']}
        assert by_name['searxng']['status'] == 'active'
        assert by_name['searxng']['active'] is True
        assert by_name['searxng']['tool_count'] == 3
        assert by_name['web-reader']['status'] == 'configured'
        assert '••••' in by_name['web-reader']['headers']['Authorization']
        assert by_name['disabled']['enabled'] is False
        assert by_name['disabled']['active'] is False
        assert by_name['disabled']['status'] == 'disabled'
        assert by_name['broken']['transport'] == 'invalid'
        assert by_name['broken']['status'] == 'invalid_config'

    def test_secrets_are_masked(self):
        """_mask_secrets hides API keys in headers and env."""
        masked = _mask_secrets(SAMPLE_MCP['web-reader']['headers'])
        assert masked['Authorization'] != 'Bearer secret123'
        assert '••••' in masked['Authorization']

    def test_server_summary_stdio(self):
        summary = _server_summary('searxng', SAMPLE_MCP['searxng'])
        assert summary['transport'] == 'stdio'
        assert summary['command'] == 'mcp-searxng'
        assert summary['args'] == ['--port', '8888']

    def test_server_summary_http(self):
        summary = _server_summary('web-reader', SAMPLE_MCP['web-reader'])
        assert summary['transport'] == 'http'
        assert summary['url'] == 'http://localhost:3001/mcp'
        assert '••••' in summary['headers']['Authorization']

    def test_server_summary_default_timeout(self):
        summary = _server_summary('minimal', {'command': 'x'})
        assert summary['timeout'] == 120

    def test_numeric_zero_enabled_flag_is_disabled(self):
        """YAML numeric false-y values should not show a disabled server as enabled."""
        assert _parse_mcp_enabled(0) is False


class TestMaskSecrets:
    """Unit tests for _mask_secrets helper."""

    def test_masks_env_values(self):
        obj = {"env": {"API_KEY": "***", "PUBLIC_VAR": "visible"}}
        result = _mask_secrets(obj)
        assert result["env"]["API_KEY"] == "••••••"
        assert result["env"]["PUBLIC_VAR"] == "visible"

    def test_masks_headers(self):
        obj = {"headers": {"Authorization": "Bearer token", "Accept": "application/json"}}
        result = _mask_secrets(obj)
        assert "••••" in result["headers"]["Authorization"]
        assert result["headers"]["Accept"] == "application/json"

    def test_passes_non_dict(self):
        assert _mask_secrets("hello") == "hello"
        assert _mask_secrets(42) == 42
        assert _mask_secrets(None) is None

    def test_handles_empty_dict(self):
        assert _mask_secrets({}) == {}

    def test_masks_password_key(self):
        obj = {"password": "hunter2"}
        result = _mask_secrets(obj)
        assert result["password"] == "••••••"
