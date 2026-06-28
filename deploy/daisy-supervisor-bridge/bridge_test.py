import contextlib
import http.server
import io
import json
import os
import socket
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

import run


STRONG_TOKEN = "0123456789abcdef0123456789abcdef"
EXAMPLE_TOKEN = "replace-me-with-a-random-token"
SENSITIVE_VALUE = "raw-nut-password-should-not-leak"
SUPERVISOR_TOKEN_VALUE = "supervisor-token-should-not-leak"


class ExplodingSupervisor:
    def supervisor_info(self):
        raise AssertionError("Supervisor must not be called")

    def addons(self):
        raise AssertionError("Supervisor must not be called")

    def addon_info(self, slug):
        raise AssertionError(f"Supervisor must not be called for {slug}")


class ShapedSupervisor:
    def __init__(self, supervisor_info, addon_info, addons=None):
        self._supervisor_info = supervisor_info
        self._addon_info = addon_info
        self._addons = addons if addons is not None else {"addons": [{"slug": "a0d7b954_nut"}]}

    def supervisor_info(self):
        return self._supervisor_info

    def addons(self):
        return self._addons

    def addon_info(self, slug):
        return self._addon_info


class BridgeStartupAndAuthTest(unittest.TestCase):
    def assert_error_response(self, request, expected_status, expected_body):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=2)

        error = raised.exception
        self.assertEqual(error.code, expected_status)
        body = error.read().decode("utf-8")
        error.close()
        self.assertEqual(json.loads(body), expected_body)
        self.assertNotIn("Traceback", body)
        return body

    def start_exploding_app(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=ExplodingSupervisor(),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        return port

    def auth_request(self, port, path, authorization=None, method="GET", data=None):
        headers = {}
        if authorization is not None:
            headers["Authorization"] = authorization
        return urllib.request.Request(
            f"http://127.0.0.1:{port}{path}",
            data=data,
            headers=headers,
            method=method,
        )

    def raw_http_request(self, port, request_bytes):
        with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
            connection.settimeout(2)
            connection.sendall(request_bytes)
            chunks = []
            while True:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
        return b"".join(chunks)

    def raw_request_bytes(self, method, path, authorization=None):
        lines = [
            f"{method} {path} HTTP/1.1",
            "Host: 127.0.0.1",
            "Connection: close",
        ]
        if authorization is not None:
            lines.append(f"Authorization: {authorization}")
        return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")

    def assert_raw_json_response(self, response, expected_status, expected_body):
        headers, separator, body = response.partition(b"\r\n\r\n")
        self.assertEqual(separator, b"\r\n\r\n", response.decode("latin-1", errors="replace"))
        status_line = headers.splitlines()[0].decode("ascii")
        self.assertEqual(int(status_line.split()[1]), expected_status)
        body_text = body.decode("utf-8")
        self.assertEqual(json.loads(body_text), expected_body)
        self.assertNotIn("Traceback", body_text)
        self.assertNotIn("<html", body_text.lower())
        return body_text

    def supervisor_response_server(self, body, status=200):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]

        def serve_once():
            try:
                connection, _address = listener.accept()
                with connection:
                    connection.recv(4096)
                    response = (
                        f"HTTP/1.1 {status} OK\r\n"
                        "Content-Type: application/json\r\n"
                        f"Content-Length: {len(body)}\r\n"
                        "Connection: close\r\n"
                        "\r\n"
                    ).encode("ascii") + body
                    connection.sendall(response)
            finally:
                listener.close()

        thread = threading.Thread(target=serve_once, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(listener.close)
        return f"http://127.0.0.1:{port}"

    def test_validate_options_rejects_blank_token(self):
        with self.assertRaisesRegex(run.ConfigError, "bridge token is required"):
            run.validate_options({"token": "", "watched_addons": ["a0d7b954_nut"]})

    def test_validate_options_rejects_short_token(self):
        with self.assertRaisesRegex(run.ConfigError, "at least 32 characters"):
            run.validate_options({"token": "short-token", "watched_addons": ["a0d7b954_nut"]})

    def test_validate_options_rejects_documented_example_token(self):
        with self.assertRaisesRegex(run.ConfigError, "documented example token"):
            run.validate_options({"token": EXAMPLE_TOKEN, "watched_addons": ["a0d7b954_nut"]})

    def test_validate_options_rejects_empty_watched_addons(self):
        with self.assertRaisesRegex(run.ConfigError, "watched_addons must contain at least one slug"):
            run.validate_options({"token": STRONG_TOKEN, "watched_addons": []})

    def test_validate_options_accepts_strong_token_and_addon_list(self):
        options = run.validate_options({"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]})
        self.assertEqual(options["token"], STRONG_TOKEN)
        self.assertEqual(options["watched_addons"], ["a0d7b954_nut"])

    def test_validate_options_rejects_token_with_surrounding_whitespace_or_control_characters(self):
        invalid_tokens = [
            f" {STRONG_TOKEN}",
            f"{STRONG_TOKEN} ",
            f"\t{STRONG_TOKEN}",
            f"{STRONG_TOKEN}\n",
            f"{STRONG_TOKEN[:8]}\r{STRONG_TOKEN[8:]}",
            f"{STRONG_TOKEN[:8]}\x00{STRONG_TOKEN[8:]}",
            f"{STRONG_TOKEN[:8]}\x85{STRONG_TOKEN[8:]}",
        ]

        for token in invalid_tokens:
            with self.subTest(token=repr(token)):
                with self.assertRaisesRegex(run.ConfigError, "whitespace|control"):
                    run.validate_options({"token": token, "watched_addons": ["a0d7b954_nut"]})

    def test_validate_options_rejects_invalid_watched_addon_slugs(self):
        invalid_slugs = [
            123,
            "",
            " ",
            "a0d7b954/nut",
            "a0d7b954?nut",
            "a0d7b954#nut",
            "..",
            "a0d7b954 nut",
            "a0d7b954\nnut",
        ]

        for slug in invalid_slugs:
            with self.subTest(slug=repr(slug)):
                with self.assertRaisesRegex(run.ConfigError, "watched_addons.*slug"):
                    run.validate_options({"token": STRONG_TOKEN, "watched_addons": [slug]})

        options = run.validate_options(
            {"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut", "ABC-123_foo"]}
        )
        self.assertEqual(options["watched_addons"], ["a0d7b954_nut", "ABC-123_foo"])

    def test_missing_or_bad_auth_to_health_returns_401_before_supervisor(self):
        port = self.start_exploding_app()
        for authorization in [None, f"Bearer {SENSITIVE_VALUE}", f"Basic {STRONG_TOKEN}"]:
            with self.subTest(authorization=authorization):
                request = self.auth_request(port, "/health", authorization=authorization)
                self.assert_error_response(request, 401, {"error": "unauthorized"})

    def test_missing_or_bad_auth_to_unknown_paths_returns_401_before_routing(self):
        port = self.start_exploding_app()
        for authorization in [None, f"Bearer {SENSITIVE_VALUE}", f"Basic {STRONG_TOKEN}"]:
            with self.subTest(authorization=authorization):
                request = self.auth_request(port, "/not-health", authorization=authorization)
                self.assert_error_response(request, 401, {"error": "unauthorized"})

    def test_missing_or_bad_auth_to_mutating_health_methods_returns_401_before_method_handling(self):
        port = self.start_exploding_app()
        for method in ["POST", "PUT", "PATCH", "DELETE"]:
            for authorization in [None, f"Bearer {SENSITIVE_VALUE}", f"Basic {STRONG_TOKEN}"]:
                with self.subTest(method=method, authorization=authorization):
                    request = self.auth_request(
                        port,
                        "/health",
                        authorization=authorization,
                        method=method,
                        data=b"{}",
                    )
                    self.assert_error_response(request, 401, {"error": "unauthorized"})

    def test_missing_or_bad_auth_to_supervisor_like_mutating_paths_returns_401_before_routing(self):
        port = self.start_exploding_app()
        for path in [
            "/addons/a0d7b954_nut/restart",
            "/addons/a0d7b954_nut/stop",
            "/addons/a0d7b954_nut/update",
            "/addons/a0d7b954_nut/install",
            "/addons/a0d7b954_nut/uninstall",
        ]:
            for authorization in [None, f"Bearer {SENSITIVE_VALUE}", f"Basic {STRONG_TOKEN}"]:
                with self.subTest(path=path, authorization=authorization):
                    request = self.auth_request(
                        port,
                        path,
                        authorization=authorization,
                        method="POST",
                        data=b"{}",
                    )
                    self.assert_error_response(request, 401, {"error": "unauthorized"})

    def test_authorization_header_must_be_exact_bearer_shape(self):
        port = self.start_exploding_app()
        invalid_headers = [
            STRONG_TOKEN,
            f"Basic {STRONG_TOKEN}",
            f"bearer {STRONG_TOKEN}",
            f"BEARER {STRONG_TOKEN}",
            f"Bearer  {STRONG_TOKEN}",
            f"Bearer\t{STRONG_TOKEN}",
            f"Bearer {STRONG_TOKEN} ",
            f"Bearer {STRONG_TOKEN}x",
            f"Bearer {STRONG_TOKEN} extra",
        ]

        for authorization in invalid_headers:
            with self.subTest(authorization=authorization):
                request = self.auth_request(port, "/health", authorization=authorization)
                self.assert_error_response(request, 401, {"error": "unauthorized"})

        duplicate_authorization_request = (
            b"GET /health HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Connection: close\r\n"
            b"Authorization: Bearer 0123456789abcdef0123456789abcdef\r\n"
            b"Authorization: Bearer raw-nut-password-should-not-leak\r\n"
            b"\r\n"
        )
        response = self.raw_http_request(port, duplicate_authorization_request)
        body = self.assert_raw_json_response(response, 401, {"error": "unauthorized"})
        self.assertNotIn(STRONG_TOKEN, body)
        self.assertNotIn(SENSITIVE_VALUE, body)

    def test_supervisor_client_rejects_invalid_json_and_non_object_payloads(self):
        invalid_json_url = self.supervisor_response_server(b"{")
        with self.assertRaises(run.SupervisorError):
            run.SupervisorClient("supervisor-token", base_url=invalid_json_url).supervisor_info()

        non_object_url = self.supervisor_response_server(b'["not", "an", "object"]')
        with self.assertRaises(run.SupervisorError):
            run.SupervisorClient("supervisor-token", base_url=non_object_url).supervisor_info()

    def test_build_health_payload_rejects_unexpected_supervisor_shapes(self):
        with self.assertRaises(run.SupervisorError):
            run.build_health_payload(
                ShapedSupervisor(
                    supervisor_info=["not", "an", "object"],
                    addon_info={"state": "started"},
                ),
                ["a0d7b954_nut"],
            )

        with self.assertRaises(run.SupervisorError):
            run.build_health_payload(
                ShapedSupervisor(
                    supervisor_info={"version": "2026.06.2", "healthy": True, "supported": True},
                    addon_info=["not", "an", "object"],
                ),
                ["a0d7b954_nut"],
            )

    def test_malformed_supervisor_payload_returns_sanitized_502(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=ShapedSupervisor(
                supervisor_info={"version": "2026.06.2", "healthy": True, "supported": True},
                addon_info=["not", "an", "object"],
            ),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            body = self.assert_error_response(request, 502, {"error": "supervisor_unavailable"})
        self.assertNotIn(STRONG_TOKEN, body)

    def test_invalid_utf8_supervisor_payload_returns_sanitized_502(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=run.SupervisorClient(
                "supervisor-token",
                base_url=self.supervisor_response_server(b"\xff"),
            ),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            body = self.assert_error_response(request, 502, {"error": "supervisor_unavailable"})

        output = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn("Traceback", body)
        self.assertNotIn("Traceback", output)
        self.assertNotIn(STRONG_TOKEN, body)
        self.assertNotIn("supervisor-token", output)

    def test_unsupported_methods_authenticate_before_method_handling(self):
        port = self.start_exploding_app()

        for method in ["TRACE", "CONNECT", "BREW"]:
            for authorization in [None, f"Bearer {SENSITIVE_VALUE}"]:
                with self.subTest(method=method, authorization=authorization):
                    response = self.raw_http_request(port, self.raw_request_bytes(method, "/health", authorization))
                    body = self.assert_raw_json_response(response, 401, {"error": "unauthorized"})
                    self.assertNotIn(SENSITIVE_VALUE, body)

            with self.subTest(method=method, authorization="valid-health"):
                response = self.raw_http_request(
                    port,
                    self.raw_request_bytes(method, "/health", f"Bearer {STRONG_TOKEN}"),
                )
                body = self.assert_raw_json_response(response, 405, {"error": "method_not_allowed"})
                self.assertNotIn(STRONG_TOKEN, body)

            with self.subTest(method=method, authorization="valid-unknown"):
                response = self.raw_http_request(
                    port,
                    self.raw_request_bytes(method, "/not-health", f"Bearer {STRONG_TOKEN}"),
                )
                body = self.assert_raw_json_response(response, 404, {"error": "not_found"})
                self.assertNotIn(STRONG_TOKEN, body)

    def test_non_ascii_authorization_header_returns_generic_401(self):
        port = self.start_exploding_app()
        request = (
            b"GET /health HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Connection: close\r\n"
            b"Authorization: Bearer \xc3\xa9-token\r\n"
            b"\r\n"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            response = self.raw_http_request(port, request)

        body = self.assert_raw_json_response(response, 401, {"error": "unauthorized"})
        output = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn("Traceback", body)
        self.assertNotIn("Traceback", output)
        self.assertNotIn("Authorization", output)

    def test_exact_health_path_is_not_widened(self):
        port = self.start_exploding_app()
        for path in ["/health/", "/health?x=y", "/Health"]:
            with self.subTest(path=path, authorization="valid"):
                request = self.auth_request(path=path, port=port, authorization=f"Bearer {STRONG_TOKEN}")
                self.assert_error_response(request, 404, {"error": "not_found"})

            for authorization in [None, f"Bearer {SENSITIVE_VALUE}"]:
                with self.subTest(path=path, authorization=authorization):
                    request = self.auth_request(path=path, port=port, authorization=authorization)
                    self.assert_error_response(request, 401, {"error": "unauthorized"})

        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=run.FakeSupervisorClient(
                supervisor_info={"version": "2026.06.2", "healthy": True, "supported": True},
                addons=[],
                addon_info={"a0d7b954_nut": {"state": "started", "password": SENSITIVE_VALUE}},
            ),
        )
        server, health_port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        with urllib.request.urlopen(
            self.auth_request(health_port, "/health", authorization=f"Bearer {STRONG_TOKEN}"),
            timeout=2,
        ) as response:
            self.assertEqual(response.status, 200)
            body = response.read().decode("utf-8")
        payload = json.loads(body)
        self.assertEqual(payload["supervisor"]["version"], "2026.06.2")
        self.assertEqual(payload["addons"][0]["slug"], "a0d7b954_nut")
        self.assertEqual(payload["addons"][0]["state"], "started")
        self.assertNotIn(STRONG_TOKEN, body)
        self.assertNotIn(SENSITIVE_VALUE, body)

    def test_default_http_access_log_does_not_leak_path_query_or_headers(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=ExplodingSupervisor(),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)

        stdout = io.StringIO()
        stderr = io.StringIO()
        request = self.auth_request(
            port,
            f"/health?token={SENSITIVE_VALUE}",
            authorization=f"Bearer {SENSITIVE_VALUE}",
        )

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assert_error_response(request, 401, {"error": "unauthorized"})

        output = stdout.getvalue() + stderr.getvalue()
        for forbidden in [
            f"/health?token={SENSITIVE_VALUE}",
            f"token={SENSITIVE_VALUE}",
            f"Bearer {SENSITIVE_VALUE}",
            "Authorization",
            "Traceback",
            SENSITIVE_VALUE,
        ]:
            self.assertNotIn(forbidden, output)

    def test_missing_supervisor_token_startup_fails_sanitized(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            options_path = os.path.join(temp_dir, "options.json")
            with open(options_path, "w", encoding="utf-8") as options_file:
                json.dump({"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]}, options_file)

            previous = os.environ.pop("SUPERVISOR_TOKEN", None)
            stdout = io.StringIO()
            stderr = io.StringIO()
            try:
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    with self.assertRaisesRegex(run.ConfigError, "SUPERVISOR_TOKEN is required"):
                        run.main(options_path=options_path, host="127.0.0.1", port=0)
            finally:
                if previous is not None:
                    os.environ["SUPERVISOR_TOKEN"] = previous

        output = stdout.getvalue() + stderr.getvalue()
        for forbidden in [
            STRONG_TOKEN,
            "Authorization",
            "Traceback",
            "password",
            '{"token"',
            "raw options",
        ]:
            self.assertNotIn(forbidden, output)

    def test_unauthorized_request_returns_generic_401(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=run.FakeSupervisorClient(
                supervisor_info={"version": "2026.06.2", "healthy": True, "supported": True},
                addons=[],
                addon_info={},
            ),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)

        request = urllib.request.Request(f"http://127.0.0.1:{port}/health")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=2)

        self.assertEqual(raised.exception.code, 401)
        body = raised.exception.read().decode("utf-8")
        raised.exception.close()
        self.assertEqual(json.loads(body), {"error": "unauthorized"})

    def test_unknown_path_returns_404_without_stack_trace(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=run.FakeSupervisorClient(
                supervisor_info={"version": "2026.06.2", "healthy": True, "supported": True},
                addons=[],
                addon_info={},
            ),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)

        request = urllib.request.Request(
            f"http://127.0.0.1:{port}/not-health",
            headers={"Authorization": f"Bearer {STRONG_TOKEN}"},
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=2)

        self.assertEqual(raised.exception.code, 404)
        body = raised.exception.read().decode("utf-8")
        raised.exception.close()
        self.assertEqual(json.loads(body), {"error": "not_found"})
        self.assertNotIn("Traceback", body)

    def test_mutating_methods_to_health_return_405_without_supervisor_call(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=ExplodingSupervisor(),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)

        for method in ["POST", "PUT", "PATCH", "DELETE"]:
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/health",
                data=b"{}",
                headers={"Authorization": f"Bearer {STRONG_TOKEN}"},
                method=method,
            )
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(request, timeout=2)

            self.assertEqual(raised.exception.code, 405)
            body = raised.exception.read().decode("utf-8")
            raised.exception.close()
            self.assertEqual(json.loads(body), {"error": "method_not_allowed"})
            self.assertNotIn("Traceback", body)
            self.assertNotIn(STRONG_TOKEN, body)

    def test_supervisor_like_mutating_paths_return_generic_error_without_supervisor_call(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=ExplodingSupervisor(),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)

        for path in [
            "/addons/a0d7b954_nut/restart",
            "/addons/a0d7b954_nut/stop",
            "/addons/a0d7b954_nut/update",
            "/addons/a0d7b954_nut/install",
            "/addons/a0d7b954_nut/uninstall",
        ]:
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}",
                data=b"{}",
                headers={"Authorization": f"Bearer {STRONG_TOKEN}"},
                method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(request, timeout=2)

            self.assertIn(raised.exception.code, (404, 405))
            body = raised.exception.read().decode("utf-8")
            raised.exception.close()
            self.assertIn(json.loads(body), [{"error": "not_found"}, {"error": "method_not_allowed"}])
            self.assertNotIn("Traceback", body)
            self.assertNotIn(STRONG_TOKEN, body)

    def test_configured_http_port_bind_failure_is_sanitized_config_error(self):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=ExplodingSupervisor(),
        )
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen(1)
            port = occupied.getsockname()[1]

            with self.assertRaisesRegex(run.ConfigError, "HTTP port .* unavailable"):
                run.start_server(app, host="127.0.0.1", port=port)


class BridgeHealthPayloadTest(unittest.TestCase):
    def auth_request(self, port, path, authorization=None, method="GET", data=None):
        headers = {}
        if authorization is not None:
            headers["Authorization"] = authorization
        return urllib.request.Request(
            f"http://127.0.0.1:{port}{path}",
            data=data,
            headers=headers,
            method=method,
        )

    def read_http_error(self, request, expected_status, expected_payload):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=2)

        error = raised.exception
        self.assertEqual(error.code, expected_status)
        body = error.read().decode("utf-8")
        error.close()
        self.assertEqual(json.loads(body), expected_payload)
        return body

    def assert_bridge_error_response(self, request):
        try:
            urllib.request.urlopen(request, timeout=2)
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 500)
            body = error.read().decode("utf-8")
            error.close()
            self.assertEqual(json.loads(body), {"error": "bridge_error"})
            self.assertEqual(body, '{"error":"bridge_error"}')
            return body
        except Exception as error:
            self.fail(f"expected sanitized 500 bridge_error response, got {type(error).__name__}: {error}")

        self.fail("expected sanitized 500 bridge_error response")

    def raw_nut_options(self, username="", password=SENSITIVE_VALUE):
        return {
            "mode": "netserver",
            "shutdown_host": False,
            "devices": [{"name": "ups", "driver": "usbhid-ups", "port": "auto"}],
            "users": [
                {
                    "username": username,
                    "password": password,
                    "upsmon": None,
                }
            ],
        }

    def nut_detail(self, options=None, network=None):
        return {
            "slug": "a0d7b954_nut",
            "name": "Network UPS Tools",
            "state": "started",
            "available": True,
            "version": "1.0.0",
            "options": options if options is not None else self.raw_nut_options(),
            "network": {"3493/tcp": 3493} if network is None else network,
            "password": SENSITIVE_VALUE,
            "SUPERVISOR_TOKEN": SUPERVISOR_TOKEN_VALUE,
            "Authorization": f"Bearer {SUPERVISOR_TOKEN_VALUE}",
            "logs": "secret log body",
            "log": "secret log body",
            "secrets": {"token": SUPERVISOR_TOKEN_VALUE},
        }

    def overview(self, slug="a0d7b954_nut", **overrides):
        overview = {
            "slug": slug,
            "name": "Network UPS Tools" if slug == "a0d7b954_nut" else "Unknown Add-on",
            "state": "started",
            "available": True,
            "version": "1.0.0",
            "options": {"password": SENSITIVE_VALUE},
            "password": SENSITIVE_VALUE,
            "SUPERVISOR_TOKEN": SUPERVISOR_TOKEN_VALUE,
            "Authorization": f"Bearer {SUPERVISOR_TOKEN_VALUE}",
            "logs": "secret log body",
            "log": "secret log body",
            "secrets": {"token": SUPERVISOR_TOKEN_VALUE},
        }
        overview.update(overrides)
        return overview

    def supervisor_info(self, **overrides):
        info = {
            "version": "2026.06.2",
            "healthy": True,
            "supported": True,
            "arch": "amd64",
            "options": {"password": SENSITIVE_VALUE},
            "password": SENSITIVE_VALUE,
            "username": "raw-user",
            "users": [{"username": "raw-user", "password": SENSITIVE_VALUE}],
            "SUPERVISOR_TOKEN": SUPERVISOR_TOKEN_VALUE,
            "Authorization": f"Bearer {SUPERVISOR_TOKEN_VALUE}",
            "logs": "secret log body",
            "log": "secret log body",
            "secrets": {"token": SUPERVISOR_TOKEN_VALUE},
        }
        info.update(overrides)
        return info

    def supervisor(self, supervisor_info=None, addons=None, details=None, detail_errors=None):
        class ControlledSupervisor:
            def __init__(self, test_case):
                self.test_case = test_case

            def supervisor_info(self):
                value = supervisor_info if supervisor_info is not None else self.test_case.supervisor_info()
                if isinstance(value, Exception):
                    raise value
                return value

            def addons(self):
                if isinstance(addons, Exception):
                    raise addons
                if addons is None:
                    return {"addons": [self.test_case.overview()]}
                return addons

            def addon_info(self, slug):
                if detail_errors and slug in detail_errors:
                    raise detail_errors[slug]
                if details is None:
                    return self.test_case.nut_detail()
                value = details.get(slug, {})
                if isinstance(value, Exception):
                    raise value
                return value

        return ControlledSupervisor(self)

    def start_bridge(self, supervisor):
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=supervisor,
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        return port

    def assert_redacted_payload(self, payload):
        encoded = json.dumps(payload, sort_keys=True)
        self.assertNotIn("raw-nut-password-should-not-leak", encoded)
        self.assertNotIn("supervisor-token-should-not-leak", encoded)
        self.assertNotIn("SUPERVISOR_TOKEN", encoded)
        self.assertNotIn("Authorization", encoded)
        self.assertNotIn('"username":', encoded)
        self.assertNotIn('"password":', encoded)
        self.assertNotIn('"options":', encoded)
        self.assertNotIn('"secrets":', encoded)
        self.assertNotIn('"logs":', encoded)
        self.assertNotIn('"log":', encoded)
        return encoded

    def assert_failure_is_redacted(self, body, output):
        combined = body + output
        for forbidden in [
            "Traceback",
            STRONG_TOKEN,
            SENSITIVE_VALUE,
            SUPERVISOR_TOKEN_VALUE,
            "SUPERVISOR_TOKEN",
            "Authorization",
            "password",
            "secret",
            "raw options",
            "raw response",
        ]:
            self.assertNotIn(forbidden, combined)

    def start_upstream(self, responses):
        class UpstreamHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(handler_self):
                status, body = responses.get(handler_self.path, (404, b'{"error":"not_found"}'))
                handler_self.send_response(status)
                handler_self.send_header("Content-Type", "application/json")
                handler_self.send_header("Content-Length", str(len(body)))
                handler_self.end_headers()
                handler_self.wfile.write(body)

            def log_message(self, format, *args):
                return

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join, 2)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def assert_supervisor_client_failure(self, responses, expected_log):
        base_url = self.start_upstream(responses)
        supervisor = run.SupervisorClient(SUPERVISOR_TOKEN_VALUE, base_url=base_url)
        port = self.start_bridge(supervisor)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            body = self.read_http_error(request, 502, {"error": "supervisor_unavailable"})

        output = stdout.getvalue() + stderr.getvalue()
        self.assertEqual(body, '{"error":"supervisor_unavailable"}')
        self.assertIn(expected_log, output)
        self.assert_failure_is_redacted(body, output)

    def test_health_payload_includes_supervisor_and_watched_addon(self):
        payload = run.build_health_payload(self.supervisor(), ["a0d7b954_nut"])

        self.assertIn("observed_at", payload)
        self.assertIn("supervisor", payload)
        self.assertIn("addons", payload)
        self.assertEqual(payload["supervisor"]["version"], "2026.06.2")
        self.assertEqual(payload["supervisor"]["healthy"], True)
        self.assertEqual(payload["supervisor"]["supported"], True)
        self.assertEqual(len(payload["addons"]), 1)
        addon = payload["addons"][0]
        self.assertEqual(addon["slug"], "a0d7b954_nut")
        self.assertEqual(addon["name"], "Network UPS Tools")
        self.assertEqual(addon["state"], "started")
        self.assertEqual(addon["available"], True)
        self.assertEqual(
            addon["config_summary"],
            {
                "mode": "netserver",
                "shutdown_host": False,
                "device_count": 1,
                "users": [{"username_set": False, "password_set": True, "upsmon": None}],
            },
        )
        self.assert_redacted_payload(payload)

    def test_nut_options_are_summarized_without_password_values(self):
        payload = run.build_health_payload(self.supervisor(), ["a0d7b954_nut"])
        addon = payload["addons"][0]

        self.assertEqual(addon["config_summary"]["users"][0]["username_set"], False)
        self.assertEqual(addon["config_summary"]["users"][0]["password_set"], True)
        encoded = self.assert_redacted_payload(payload)
        self.assertIn('"username_set"', encoded)
        self.assertIn('"password_set"', encoded)

    def test_default_deny_omits_config_summary_for_unknown_addon(self):
        detail = {
            "slug": "unknown_addon",
            "name": "Unknown Add-on",
            "state": "started",
            "available": True,
            "options": self.raw_nut_options(),
            "password": SENSITIVE_VALUE,
            "SUPERVISOR_TOKEN": SUPERVISOR_TOKEN_VALUE,
            "Authorization": f"Bearer {SUPERVISOR_TOKEN_VALUE}",
            "logs": "secret log body",
            "log": "secret log body",
            "secrets": {"token": SUPERVISOR_TOKEN_VALUE},
        }
        payload = run.build_health_payload(
            self.supervisor(
                addons={"addons": [self.overview(slug="unknown_addon")]},
                details={"unknown_addon": detail},
            ),
            ["unknown_addon"],
        )

        addon = payload["addons"][0]
        self.assertEqual(addon["slug"], "unknown_addon")
        self.assertNotIn("config_summary", addon)
        self.assertEqual(addon["config_warnings"], [])
        self.assert_redacted_payload(payload)

    def test_nut_blank_username_and_password_emit_critical_warnings(self):
        options = self.raw_nut_options(username="", password="")
        payload = run.build_health_payload(
            self.supervisor(details={"a0d7b954_nut": self.nut_detail(options=options)}),
            ["a0d7b954_nut"],
        )

        warnings = payload["addons"][0]["config_warnings"]
        self.assertIn(
            {
                "code": "nut_username_blank",
                "severity": "critical",
                "message": "NUT user username is blank.",
            },
            warnings,
        )
        self.assertIn(
            {
                "code": "nut_password_blank",
                "severity": "critical",
                "message": "NUT user password is blank.",
            },
            warnings,
        )
        encoded = self.assert_redacted_payload(payload)
        self.assertIn('"username_set"', encoded)
        self.assertIn('"password_set"', encoded)
        self.assertIn("nut_username_blank", encoded)
        self.assertIn("nut_password_blank", encoded)

    def test_unmapped_nut_port_emits_warning(self):
        payload = run.build_health_payload(
            self.supervisor(details={"a0d7b954_nut": self.nut_detail(network={})}),
            ["a0d7b954_nut"],
        )

        self.assertIn(
            {
                "code": "nut_port_unmapped",
                "severity": "warning",
                "message": "NUT netserver port 3493 is not mapped.",
            },
            payload["addons"][0]["config_warnings"],
        )
        self.assert_redacted_payload(payload)

    def test_individual_addon_info_failure_keeps_200_shape_with_unknown_state(self):
        payload = run.build_health_payload(
            self.supervisor(
                detail_errors={
                    "a0d7b954_nut": run.SupervisorError(
                        f"failed {SENSITIVE_VALUE} Authorization {SUPERVISOR_TOKEN_VALUE}"
                    )
                }
            ),
            ["a0d7b954_nut"],
        )

        self.assertEqual(
            payload["addons"],
            [
                {
                    "slug": "a0d7b954_nut",
                    "name": "a0d7b954_nut",
                    "state": "unknown",
                    "available": False,
                    "bridge_warnings": [
                        {
                            "code": "addon_info_unavailable",
                            "severity": "warning",
                            "message": "Supervisor info for add-on a0d7b954_nut was unavailable.",
                        }
                    ],
                    "config_warnings": [],
                }
            ],
        )
        self.assert_redacted_payload(payload)

    def test_supervisor_auth_failure_returns_generic_502_body(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    401,
                    b'{"error":"Authorization Bearer supervisor-token-should-not-leak raw-nut-password-should-not-leak"}',
                )
            },
            "Supervisor API authorization failed",
        )

    def test_supervisor_5xx_failure_returns_generic_502_body(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    500,
                    b'{"error":"Authorization Bearer supervisor-token-should-not-leak raw-nut-password-should-not-leak"}',
                )
            },
            "Supervisor API unavailable",
        )

    def test_bridge_handler_failure_returns_generic_500_without_leaks(self):
        class ExplodingApp:
            options = {"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]}

            def health_payload(self):
                raise RuntimeError(
                    f"Traceback fake {STRONG_TOKEN} raw-nut-password-should-not-leak "
                    "SUPERVISOR_TOKEN Authorization"
                )

        server, port = run.start_test_server(ExplodingApp())
        self.addCleanup(server.shutdown)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            body = self.read_http_error(request, 500, {"error": "bridge_error"})

        output = stdout.getvalue() + stderr.getvalue()
        self.assertEqual(body, '{"error":"bridge_error"}')
        self.assertIn("Bridge handler failed", output)
        self.assert_failure_is_redacted(body, output)

    def test_bridge_auth_path_failure_returns_generic_500_without_leaks(self):
        original_authorized = run.BridgeRequestHandler._authorized

        def exploding_authorized(handler):
            raise RuntimeError(
                f"Traceback fake {STRONG_TOKEN} raw-nut-password-should-not-leak "
                "SUPERVISOR_TOKEN Authorization"
            )

        run.BridgeRequestHandler._authorized = exploding_authorized
        self.addCleanup(setattr, run.BridgeRequestHandler, "_authorized", original_authorized)

        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=run.FakeSupervisorClient(
                supervisor_info={"version": "2026.06.2", "healthy": True, "supported": True},
                addons={"addons": []},
                addon_info={},
            ),
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            body = self.assert_bridge_error_response(request)

        output = stdout.getvalue() + stderr.getvalue()
        self.assertIn("Bridge handler failed", output)
        self.assert_failure_is_redacted(body, output)

    def test_unserializable_success_payload_returns_generic_500_without_leaks(self):
        class UnserializableApp:
            options = {"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]}

            def health_payload(self):
                return {
                    "bad": object(),
                    "token": STRONG_TOKEN,
                    "password": "raw-nut-password-should-not-leak",
                    "SUPERVISOR_TOKEN": SUPERVISOR_TOKEN_VALUE,
                    "Authorization": f"Bearer {SUPERVISOR_TOKEN_VALUE}",
                }

        server, port = run.start_test_server(UnserializableApp())
        self.addCleanup(server.shutdown)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            body = self.assert_bridge_error_response(request)

        output = stdout.getvalue() + stderr.getvalue()
        self.assertIn("Bridge handler failed", output)
        self.assert_failure_is_redacted(body, output)

    def test_sanitizers_allowlist_fields_and_omit_raw_secret_like_fields(self):
        options = self.raw_nut_options(username="", password="")
        raw_detail = self.nut_detail(options=options)
        raw_detail.update(
            {
                "username": "raw-user-should-not-leak",
                "users": [{"username": "raw-user", "password": SENSITIVE_VALUE}],
            }
        )
        supervisor = self.supervisor(
            supervisor_info=self.supervisor_info(username="raw-user-should-not-leak"),
            addons={"addons": [self.overview(username="raw-user-should-not-leak")]},
            details={"a0d7b954_nut": raw_detail},
        )
        app = run.BridgeApp(
            options={"token": STRONG_TOKEN, "watched_addons": ["a0d7b954_nut"]},
            supervisor=supervisor,
        )
        server, port = run.start_test_server(app)
        self.addCleanup(server.shutdown)
        stdout = io.StringIO()
        stderr = io.StringIO()

        request = self.auth_request(port, "/health", authorization=f"Bearer {STRONG_TOKEN}")
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 200)
                body = response.read().decode("utf-8")

        payload = json.loads(body)
        encoded = self.assert_redacted_payload(payload)
        output = stdout.getvalue() + stderr.getvalue()
        for forbidden in [
            SENSITIVE_VALUE,
            SUPERVISOR_TOKEN_VALUE,
            "raw-user-should-not-leak",
            '"options":',
            '"password":',
            '"secrets":',
            '"username":',
            '"logs":',
            '"log":',
            '"Authorization":',
            '"SUPERVISOR_TOKEN":',
        ]:
            self.assertNotIn(forbidden, body)
            self.assertNotIn(forbidden, output)
        self.assertIn('"username_set"', encoded)
        self.assertIn('"password_set"', encoded)
        self.assertIn("nut_username_blank", encoded)
        self.assertIn("nut_password_blank", encoded)

    def test_supervisor_info_invalid_json_returns_generic_502_without_leaks(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    200,
                    b'{"token":"supervisor-token-should-not-leak","password":"raw-nut-password-should-not-leak"',
                )
            },
            "Supervisor API unavailable",
        )

    def test_supervisor_info_unexpected_shape_returns_generic_502_without_leaks(self):
        self.assert_supervisor_client_failure(
            {"/supervisor/info": (200, b'["supervisor-token-should-not-leak","raw-nut-password-should-not-leak"]')},
            "Supervisor API unavailable",
        )

    def test_addons_invalid_json_returns_generic_502_without_leaks(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    200,
                    b'{"version":"2026.06.2","healthy":true,"supported":true}',
                ),
                "/addons": (
                    200,
                    b'{"token":"supervisor-token-should-not-leak","password":"raw-nut-password-should-not-leak"',
                ),
            },
            "Supervisor API unavailable",
        )

    def test_addons_unexpected_shape_returns_generic_502_without_leaks(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    200,
                    b'{"version":"2026.06.2","healthy":true,"supported":true}',
                ),
                "/addons": (
                    200,
                    b'{"addons":{"slug":"a0d7b954_nut","password":"raw-nut-password-should-not-leak"}}',
                ),
            },
            "Supervisor API unavailable",
        )

    def test_addon_info_invalid_json_returns_generic_502_without_leaks(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    200,
                    b'{"version":"2026.06.2","healthy":true,"supported":true}',
                ),
                "/addons": (
                    200,
                    b'{"addons":[{"slug":"a0d7b954_nut","name":"Network UPS Tools","state":"started","available":true}]}',
                ),
                "/addons/a0d7b954_nut/info": (
                    200,
                    b'{"token":"supervisor-token-should-not-leak","password":"raw-nut-password-should-not-leak"',
                ),
            },
            "Supervisor API unavailable",
        )

    def test_addon_info_unexpected_shape_returns_generic_502_without_leaks(self):
        self.assert_supervisor_client_failure(
            {
                "/supervisor/info": (
                    200,
                    b'{"version":"2026.06.2","healthy":true,"supported":true}',
                ),
                "/addons": (
                    200,
                    b'{"addons":[{"slug":"a0d7b954_nut","name":"Network UPS Tools","state":"started","available":true}]}',
                ),
                "/addons/a0d7b954_nut/info": (
                    200,
                    b'["supervisor-token-should-not-leak","raw-nut-password-should-not-leak"]',
                ),
            },
            "Supervisor API unavailable",
        )


if __name__ == "__main__":
    unittest.main()
