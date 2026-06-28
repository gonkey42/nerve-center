import datetime
import hmac
import http.server
import json
import os
import re
import socketserver
import sys
import urllib.error
import urllib.request


EXAMPLE_TOKEN = "replace-me-with-a-random-token"
SLUG_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")


class ConfigError(RuntimeError):
    pass


class SupervisorError(RuntimeError):
    pass


class SupervisorAuthError(SupervisorError):
    pass


class BridgeApp:
    def __init__(self, options, supervisor):
        self.options = validate_options(options)
        self.supervisor = supervisor

    def health_payload(self):
        return build_health_payload(self.supervisor, self.options["watched_addons"])


class SupervisorClient:
    def __init__(self, token, base_url="http://supervisor"):
        self.token = token
        self.base_url = base_url.rstrip("/")

    def supervisor_info(self):
        return self._get_json("/supervisor/info")

    def addons(self):
        return self._get_json("/addons")

    def addon_info(self, slug):
        return self._get_json(f"/addons/{slug}/info")

    def _get_json(self, path):
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise SupervisorAuthError("Supervisor request unauthorized") from None
            raise SupervisorError("Supervisor request failed") from None
        except urllib.error.URLError:
            raise SupervisorError("Supervisor request failed") from None


class FakeSupervisorClient:
    def __init__(self, supervisor_info, addons, addon_info):
        self._supervisor_info = supervisor_info
        self._addons = addons
        self._addon_info = addon_info

    def supervisor_info(self):
        return dict(self._supervisor_info)

    def addons(self):
        return list(self._addons)

    def addon_info(self, slug):
        return dict(self._addon_info.get(slug, {}))


def load_options(path="/data/options.json"):
    try:
        with open(path, "r", encoding="utf-8") as options_file:
            options = json.load(options_file)
    except OSError:
        raise ConfigError("unable to load add-on options") from None
    except json.JSONDecodeError:
        raise ConfigError("unable to parse add-on options") from None

    if not isinstance(options, dict):
        raise ConfigError("add-on options must be an object")
    return options


def validate_options(options):
    if not isinstance(options, dict):
        raise ConfigError("add-on options must be an object")

    token = options.get("token")
    if not isinstance(token, str) or token == "":
        raise ConfigError("bridge token is required")
    if token == EXAMPLE_TOKEN:
        raise ConfigError("bridge token must not use the documented example token")
    if token != token.strip():
        raise ConfigError("bridge token must not contain surrounding whitespace")
    if _contains_control_character(token):
        raise ConfigError("bridge token must not contain control characters")
    if len(token) < 32:
        raise ConfigError("bridge token must be at least 32 characters")

    watched_addons = options.get("watched_addons")
    if not isinstance(watched_addons, list) or not watched_addons:
        raise ConfigError("watched_addons must contain at least one slug")

    normalized_slugs = []
    for slug in watched_addons:
        if (
            not isinstance(slug, str)
            or slug.strip() == ""
            or _contains_control_character(slug)
            or not SLUG_PATTERN.fullmatch(slug)
        ):
            raise ConfigError("watched_addons entries must be safe slug values")
        normalized_slugs.append(slug)

    return {"token": token, "watched_addons": normalized_slugs}


def build_health_payload(supervisor, watched_addons):
    supervisor_info = supervisor.supervisor_info()
    addon_payloads = []

    for slug in watched_addons:
        addon_info = supervisor.addon_info(slug)
        addon_payloads.append({"slug": slug, "state": _string_or_none(addon_info.get("state"))})

    return {
        "checked_at": _utc_now(),
        "supervisor": {
            "healthy": bool(supervisor_info.get("healthy")),
            "supported": bool(supervisor_info.get("supported")),
            "version": _string_or_none(supervisor_info.get("version")),
        },
        "watched_addons": addon_payloads,
    }


class BridgeRequestHandler(http.server.BaseHTTPRequestHandler):
    server_version = "DaisySupervisorBridge"
    sys_version = ""

    def handle_one_request(self):
        try:
            self.raw_requestline = self.rfile.readline(65537)
            if len(self.raw_requestline) > 65536:
                self.requestline = ""
                self.request_version = ""
                self.command = ""
                self.send_error(414)
                return
            if not self.raw_requestline:
                self.close_connection = True
                return
            if not self.parse_request():
                return
            self._handle_bridge_request()
            self.wfile.flush()
        except TimeoutError:
            self.close_connection = True

    def do_GET(self):
        self._handle_bridge_request()

    def do_HEAD(self):
        self._handle_bridge_request()

    def do_POST(self):
        self._handle_bridge_request()

    def do_PUT(self):
        self._handle_bridge_request()

    def do_PATCH(self):
        self._handle_bridge_request()

    def do_DELETE(self):
        self._handle_bridge_request()

    def do_OPTIONS(self):
        self._handle_bridge_request()

    def log_message(self, format, *args):
        return

    def _handle_bridge_request(self):
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return

        if self.path != "/health":
            self._send_json(404, {"error": "not_found"})
            return

        if self.command != "GET":
            self._send_json(405, {"error": "method_not_allowed"})
            return

        try:
            payload = self.server.app.health_payload()
        except SupervisorError:
            self._send_json(502, {"error": "supervisor_unavailable"})
            return

        self._send_json(200, payload)

    def _authorized(self):
        expected = f"Bearer {self.server.app.options['token']}"
        authorization = self.headers.get("Authorization")
        if authorization is None:
            return False
        return hmac.compare_digest(authorization.encode("utf-8"), expected.encode("utf-8"))

    def _send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class BridgeHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address, handler_class, app):
        self.app = app
        super().__init__(server_address, handler_class)

    def shutdown(self):
        super().shutdown()
        super().server_close()


def start_server(app, host="0.0.0.0", port=9567):
    try:
        return BridgeHTTPServer((host, port), BridgeRequestHandler, app)
    except OSError:
        raise ConfigError(f"HTTP port {port} unavailable") from None


def start_test_server(app):
    server = start_server(app, host="127.0.0.1", port=0)
    thread = socketserver.threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, server.server_address[1]


def main(options_path="/data/options.json", host="0.0.0.0", port=9567):
    options = load_options(options_path)
    supervisor_token = os.environ.get("SUPERVISOR_TOKEN")
    if not supervisor_token:
        raise ConfigError("SUPERVISOR_TOKEN is required")

    app = BridgeApp(options=options, supervisor=SupervisorClient(supervisor_token))
    server = start_server(app, host=host, port=port)
    server.serve_forever()


def _contains_control_character(value):
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def _string_or_none(value):
    if value is None:
        return None
    return str(value)


def _utc_now():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


if __name__ == "__main__":
    try:
        main()
    except ConfigError as error:
        print(f"startup_error: {error}", file=sys.stderr)
        sys.exit(1)
