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
NETWORK_KEY_PATTERN = re.compile(r"^\d+/(tcp|udp)$")
SENSITIVE_TEXT_MARKERS = [
    "auth",
    "credential",
    "password",
    "passwd",
    "passphrase",
    "token",
    "key",
    "secret",
    "cookie",
    "session",
    "sid",
    "csrf",
    "traceback",
]
SENSITIVE_KEY_PATTERN = (
    r"[A-Za-z0-9_-]*(?:"
    + "|".join(SENSITIVE_TEXT_MARKERS)
    + r")[A-Za-z0-9_-]*"
)
SENSITIVE_QUOTED_KEY_VALUE_PATTERN = re.compile(
    r"([\"'])("
    + SENSITIVE_KEY_PATTERN
    + r")\1(\s*(?:=>|=|:)\s*)([\"'])(?:[^\"']*)\4",
    re.IGNORECASE,
)
SENSITIVE_KEY_VALUE_PATTERN = re.compile(
    r"\b("
    + SENSITIVE_KEY_PATTERN
    + r")\b(\s*(?:=>|=|:)\s*|\s+)(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)",
    re.IGNORECASE,
)


class ConfigError(RuntimeError):
    pass


class SupervisorError(RuntimeError):
    pass


class SupervisorAuthError(SupervisorError):
    pass


class SupervisorMalformedError(SupervisorError):
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
        return _require_object(self.get_json("/supervisor/info"))

    def addons(self):
        return _require_object(self.get_json("/addons"))

    def addon_info(self, slug):
        return _require_object(self.get_json(f"/addons/{slug}/info"))

    def get_json(self, path):
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return unwrap_supervisor_response(json.loads(response.read().decode("utf-8")))
        except urllib.error.HTTPError as error:
            error.close()
            if error.code in (401, 403):
                raise SupervisorAuthError("Supervisor API authorization failed") from None
            raise SupervisorError("Supervisor API request failed") from None
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise SupervisorMalformedError("Supervisor API response malformed") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise SupervisorError("Supervisor API unavailable") from None

    def _get_json(self, path):
        return self.get_json(path)


class FakeSupervisorClient:
    def __init__(self, supervisor_info, addons, addon_info):
        self._supervisor_info = supervisor_info
        self._addons = addons
        self._addon_info = addon_info

    def supervisor_info(self):
        return dict(self._supervisor_info)

    def addons(self):
        if isinstance(self._addons, dict):
            return dict(self._addons)
        return {"addons": list(self._addons)}

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
    supervisor_info = _require_object(supervisor.supervisor_info())
    addon_overviews = _addon_overviews_by_slug(supervisor.addons())
    addon_payloads = []

    for slug in watched_addons:
        overview = addon_overviews.get(slug, {})
        try:
            addon_info = _require_object(supervisor.addon_info(slug))
        except SupervisorMalformedError:
            raise
        except SupervisorError:
            addon_payloads.append(_unavailable_addon(slug))
            continue

        addon_payloads.append(sanitize_addon_info(slug, overview, addon_info))

    return {
        "observed_at": iso_utc_now(),
        "supervisor": sanitize_supervisor_info(supervisor_info),
        "addons": addon_payloads,
    }


def sanitize_supervisor_info(raw):
    _validate_supervisor_info(raw)

    sanitized = {
        "healthy": raw.get("healthy"),
        "supported": raw.get("supported"),
        "version": _string_or_none(raw.get("version")),
    }
    if "version_latest" in raw:
        sanitized["version_latest"] = _string_or_none(raw.get("version_latest"))
    if "update_available" in raw:
        sanitized["update_available"] = raw.get("update_available")
    if "channel" in raw:
        sanitized["channel"] = _string_or_none(raw.get("channel"))
    if "arch" in raw:
        sanitized["arch"] = _string_or_none(raw.get("arch"))
    return sanitized


def sanitize_addon_info(slug, overview, detail):
    _validate_addon_info(overview)
    _validate_addon_info(detail, require_core=True)

    addon = {
        "slug": slug,
        "name": _first_string(detail.get("name"), overview.get("name"), slug),
        "state": _first_string(detail.get("state"), overview.get("state"), "unknown"),
        "available": _first_bool(detail.get("available"), overview.get("available"), False),
        "bridge_warnings": [],
        "config_warnings": [],
    }

    version = _first_string(detail.get("version"), overview.get("version"), None)
    if version is not None:
        addon["version"] = version

    version_latest = _first_string(detail.get("version_latest"), overview.get("version_latest"), None)
    if version_latest is not None:
        addon["version_latest"] = version_latest

    update_available = _first_optional_bool(detail.get("update_available"), overview.get("update_available"))
    if update_available is not None:
        addon["update_available"] = update_available

    boot = _first_string(detail.get("boot"), overview.get("boot"), None)
    if boot is not None:
        addon["boot"] = boot

    startup = _first_string(detail.get("startup"), overview.get("startup"), None)
    if startup is not None:
        addon["startup"] = startup

    protected = _first_optional_bool(detail.get("protected"), overview.get("protected"))
    if protected is not None:
        addon["protected"] = protected

    network = _network_or_empty(detail.get("network"))
    if network:
        addon["network"] = network

    if slug == "a0d7b954_nut":
        config_summary, config_warnings = sanitize_nut_config(
            detail.get("options"),
            detail.get("network"),
        )
        addon["config_summary"] = config_summary
        addon["config_warnings"] = config_warnings

    return addon


def sanitize_nut_config(options, network):
    if not isinstance(options, dict):
        options = {}

    mode = _string_or_none(options.get("mode"))
    users = []
    warnings = []
    username_blank = False
    password_blank = False

    raw_users = options.get("users")
    if not isinstance(raw_users, list):
        raw_users = []

    for raw_user in raw_users:
        if not isinstance(raw_user, dict):
            continue

        username_set = _non_empty_string(raw_user.get("username"))
        password_set = _non_empty_string(raw_user.get("password"))
        username_blank = username_blank or not username_set
        password_blank = password_blank or not password_set
        users.append(
            {
                "username_set": username_set,
                "password_set": password_set,
                "upsmon": _safe_upsmon(raw_user.get("upsmon")),
            }
        )

    if not users and mode != "netclient":
        username_blank = True
        password_blank = True

    if mode != "netclient" and username_blank:
        warnings.append(problem("nut_username_blank", "critical", "NUT user username is blank."))
    if mode != "netclient" and password_blank:
        warnings.append(problem("nut_password_blank", "critical", "NUT user password is blank."))

    if mode == "netserver" and not _network_port_mapped(network, "3493"):
        warnings.append(problem("nut_port_unmapped", "warning", "NUT netserver port 3493 is not mapped."))

    config_summary = {
        "mode": mode,
        "shutdown_host": _bool_or_none(options.get("shutdown_host")),
        "device_count": _device_count(options.get("devices")),
        "users": users,
    }

    if mode == "netclient":
        config_summary.update(
            {
                "remote_ups_name_set": _non_empty_string(options.get("remote_ups_name")),
                "remote_ups_host_set": _non_empty_string(options.get("remote_ups_host")),
                "remote_ups_user_set": _non_empty_string(options.get("remote_ups_user")),
                "remote_ups_password_set": _non_empty_string(options.get("remote_ups_password")),
            }
        )

    return (
        config_summary,
        warnings,
    )


def problem(code, severity, message):
    return {"code": code, "severity": severity, "message": message}


def iso_utc_now():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


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
            self._safe_handle_bridge_request()
            self.wfile.flush()
        except TimeoutError:
            self.close_connection = True
        except Exception:
            self._send_bridge_error()

    def do_GET(self):
        self._safe_handle_bridge_request()

    def do_HEAD(self):
        self._safe_handle_bridge_request()

    def do_POST(self):
        self._safe_handle_bridge_request()

    def do_PUT(self):
        self._safe_handle_bridge_request()

    def do_PATCH(self):
        self._safe_handle_bridge_request()

    def do_DELETE(self):
        self._safe_handle_bridge_request()

    def do_OPTIONS(self):
        self._safe_handle_bridge_request()

    def log_message(self, format, *args):
        return

    def send_error(self, code, message=None, explain=None):
        self.request_version = "HTTP/1.1"
        if not hasattr(self, "command"):
            self.command = ""
        error = "request_too_large" if code == 414 else "bad_request"
        self._send_json(code, {"error": error})

    def _safe_handle_bridge_request(self):
        try:
            self._handle_bridge_request()
        except SupervisorAuthError:
            print("Supervisor API authorization failed", file=sys.stderr)
            self._send_json(502, {"error": "supervisor_unavailable"})
            return
        except SupervisorError:
            print("Supervisor API unavailable", file=sys.stderr)
            self._send_json(502, {"error": "supervisor_unavailable"})
            return
        except Exception:
            self._send_bridge_error()
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

        payload = self.server.app.health_payload()
        self._send_json(200, payload)

    def _send_bridge_error(self):
        print("Bridge handler failed", file=sys.stderr)
        try:
            self._send_json(500, {"error": "bridge_error"})
        except Exception:
            self.close_connection = True

    def _authorized(self):
        expected = f"Bearer {self.server.app.options['token']}"
        authorizations = self.headers.get_all("Authorization", [])
        if len(authorizations) != 1:
            return False
        authorization = authorizations[0]
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
    # socketserver imports threading internally; use it to honor the Task 1 import whitelist.
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
    return any(not character.isprintable() for character in value)


def _require_object(payload):
    if not isinstance(payload, dict):
        raise SupervisorMalformedError("Supervisor response malformed")
    return payload


def unwrap_supervisor_response(payload):
    payload = _require_object(payload)
    if payload.get("result") == "ok" and "data" in payload:
        return _require_object(payload["data"])
    if payload.get("result") == "error":
        raise SupervisorError("Supervisor API request failed")
    return payload


def _addon_overviews_by_slug(payload):
    payload = _require_object(payload)
    addons = payload.get("addons")
    if not isinstance(addons, list):
        raise SupervisorMalformedError("Supervisor add-ons response malformed")

    by_slug = {}
    for addon in addons:
        if not isinstance(addon, dict):
            raise SupervisorMalformedError("Supervisor add-ons response malformed")
        slug = addon.get("slug")
        if not _safe_slug(slug):
            raise SupervisorMalformedError("Supervisor add-ons response malformed")
        by_slug[slug] = addon
    return by_slug


def _validate_supervisor_info(raw):
    _require_bool_field(raw, "healthy", required=True)
    _require_bool_field(raw, "supported", required=True)
    _require_string_field(raw, "version")
    _require_string_field(raw, "version_latest")
    _require_bool_field(raw, "update_available")
    _require_string_field(raw, "channel")
    _require_string_field(raw, "arch")


def _validate_addon_info(raw, require_core=False):
    _require_slug_field(raw, "slug", required=require_core)
    _require_string_field(raw, "name", required=require_core)
    _require_string_field(raw, "state", required=require_core)
    _require_string_field(raw, "version", required=require_core)
    _require_string_field(raw, "version_latest", required=require_core)
    _require_string_field(raw, "boot", required=require_core)
    _require_string_field(raw, "startup", required=require_core)
    _require_bool_field(raw, "available", required=require_core)
    _require_bool_field(raw, "update_available", required=require_core)
    _require_bool_field(raw, "protected", required=require_core)
    _require_object_field(raw, "network", required=require_core)
    _require_object_field(raw, "options", required=require_core)


def _require_slug_field(raw, field, required=False):
    if field not in raw:
        if required:
            raise SupervisorMalformedError("Supervisor response malformed")
        return
    if not _safe_slug(raw[field]):
        raise SupervisorMalformedError("Supervisor response malformed")


def _require_string_field(raw, field, required=False):
    if field not in raw:
        if required:
            raise SupervisorMalformedError("Supervisor response malformed")
        return
    if required and raw[field] is None:
        raise SupervisorMalformedError("Supervisor response malformed")
    if field in raw and raw[field] is not None and not isinstance(raw[field], str):
        raise SupervisorMalformedError("Supervisor response malformed")


def _require_bool_field(raw, field, required=False):
    if required and field not in raw:
        raise SupervisorMalformedError("Supervisor response malformed")
    if field in raw and not isinstance(raw[field], bool):
        raise SupervisorMalformedError("Supervisor response malformed")


def _require_object_field(raw, field, required=False):
    if field not in raw:
        if required:
            raise SupervisorMalformedError("Supervisor response malformed")
        return
    if required and raw[field] is None:
        raise SupervisorMalformedError("Supervisor response malformed")
    if field in raw and raw[field] is not None and not isinstance(raw[field], dict):
        raise SupervisorMalformedError("Supervisor response malformed")


def _safe_slug(slug):
    return (
        isinstance(slug, str)
        and slug.strip() != ""
        and not _contains_control_character(slug)
        and SLUG_PATTERN.fullmatch(slug) is not None
    )


def _unavailable_addon(slug):
    return {
        "slug": slug,
        "name": slug,
        "state": "unknown",
        "available": False,
        "bridge_warnings": [
            problem(
                "addon_info_unavailable",
                "warning",
                f"Supervisor info for add-on {slug} was unavailable.",
            )
        ],
        "config_warnings": [],
    }


def _string_or_none(value):
    if isinstance(value, str):
        return _sanitize_string(value)
    return None


def _first_string(*values):
    for value in values:
        if isinstance(value, str) and value != "":
            return _sanitize_string(value)
    return None


def _sanitize_string(value):
    value = re.sub(r"Traceback", "[REDACTED]", value, flags=re.IGNORECASE)
    value = re.sub(
        r"Authorization:\s*Bearer\s+[^,\s;]+",
        "[REDACTED]",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(r"Bearer\s+[^,\s;]+", "Bearer [REDACTED]", value, flags=re.IGNORECASE)
    value = SENSITIVE_QUOTED_KEY_VALUE_PATTERN.sub(_redact_quoted_sensitive_key_value, value)
    value = SENSITIVE_KEY_VALUE_PATTERN.sub(_redact_unquoted_sensitive_key_value, value)
    value = re.sub(r"Authorization", "[REDACTED]", value, flags=re.IGNORECASE)
    value = re.sub(
        r"[A-Za-z0-9_-]*token[A-Za-z0-9_-]*",
        "[REDACTED]",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"[A-Za-z0-9_-]*password[A-Za-z0-9_-]*",
        "[REDACTED]",
        value,
        flags=re.IGNORECASE,
    )
    return value


def _redact_quoted_sensitive_key_value(match):
    key_quote = match.group(1)
    key = match.group(2)
    separator = match.group(3)
    value_quote = match.group(4)
    return f"{key_quote}{key}{key_quote}{separator}{value_quote}[REDACTED]{value_quote}"


def _redact_unquoted_sensitive_key_value(match):
    return f"{match.group(1)}{match.group(2)}[REDACTED]"


def _first_bool(*values):
    for value in values:
        if isinstance(value, bool):
            return value
    return False


def _first_optional_bool(*values):
    for value in values:
        if isinstance(value, bool):
            return value
    return None


def _bool_or_none(value):
    if isinstance(value, bool):
        return value
    return None


def _non_empty_string(value):
    return isinstance(value, str) and value.strip() != ""


def _safe_upsmon(value):
    if value is None:
        return None
    if value in ("master", "slave", "primary", "secondary"):
        return value
    return None


def _device_count(devices):
    if not isinstance(devices, list):
        return 0
    return sum(1 for device in devices if isinstance(device, dict))


def _network_port_mapped(network, port):
    if not isinstance(network, dict):
        return False
    for key in (port, f"{port}/tcp"):
        value = network.get(key)
        if value not in (None, False, ""):
            return True
    return False


def _network_or_empty(network):
    if network is None:
        return {}
    if not isinstance(network, dict):
        raise SupervisorMalformedError("Supervisor response malformed")

    sanitized = {}
    for key, value in network.items():
        if not isinstance(key, str) or not NETWORK_KEY_PATTERN.fullmatch(key):
            continue
        if value is None or (isinstance(value, int) and not isinstance(value, bool)):
            sanitized[key] = value
    return sanitized


def _utc_now():
    return iso_utc_now()


if __name__ == "__main__":
    try:
        main()
    except ConfigError as error:
        print(f"startup_error: {error}", file=sys.stderr)
        sys.exit(1)
