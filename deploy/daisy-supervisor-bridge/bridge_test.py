import contextlib
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


class ExplodingSupervisor:
    def supervisor_info(self):
        raise AssertionError("Supervisor must not be called")

    def addons(self):
        raise AssertionError("Supervisor must not be called")

    def addon_info(self, slug):
        raise AssertionError(f"Supervisor must not be called for {slug}")


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
        self.assertEqual(payload["watched_addons"], [{"slug": "a0d7b954_nut", "state": "started"}])
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


if __name__ == "__main__":
    unittest.main()
