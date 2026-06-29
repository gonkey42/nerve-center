# Daisy Supervisor Bridge

Read-only Home Assistant local add-on that exposes sanitized Supervisor health for NerveCenter on `GET /health`.

## Security Model

The bridge keeps the Supervisor token inside the add-on and never returns raw Supervisor responses, add-on options, add-on logs, request headers, passwords, usernames, or secret-like fields. Health responses are rebuilt from allowlisted fields only.

Do not record or commit real secret values, captured Daisy `/data/options.json` contents, raw Supervisor responses, or raw add-on config in this README, tests, PR bodies, logs, screenshots, or other repository artifacts.

The only public route is authenticated `GET /health`. Mutating methods and Supervisor-like paths are not proxied. Error bodies are sanitized for `401`, `404`, `405`, `500`, and `502`.

Generate a bridge token with:

```bash
openssl rand -hex 32
```

## Home Assistant Local Add-on Installation

1. Copy this directory into Daisy's Home Assistant local add-ons directory.
2. Reload the add-on store and install `Daisy Supervisor Bridge`.
3. Configure a random `token` and the required `watched_addons`.
4. Confirm the add-on installs, starts, binds `9567/tcp`, and runs the bridge command through `/command/with-contenv` so the Supervisor token is visible to `run.py`.

## Required Options

`token` must be a random value of at least 32 characters and must not be the documented example value.

`watched_addons` must contain the add-on slugs to summarize. The initial Daisy target is:

```text
a0d7b954_nut
```

## Role Verification

`hassio_role: manager` is required on Daisy because `default` cannot read the add-on overview endpoint. Verify the role on Daisy against all three Supervisor endpoints before relying on the bridge:

```text
/addons
/addons/a0d7b954_nut/info
/supervisor/info
```

Role gate:

```text
Endpoint                         Observed status             Selected role
/addons                          403 default, 200 manager    manager
/addons/a0d7b954_nut/info         200 default, 200 manager    manager
/supervisor/info                  200 default, 200 manager    manager
```

If any endpoint fails, raise only to the least Home Assistant Supervisor role that works, update `config.yaml`, and record the endpoint, observed status code, and selected role here and in the PR body.

Architecture gate:

```text
Observed Daisy add-on architecture: amd64, from read-only `ha info --raw-json` on 2026-06-28; Daisy reported `arch: "amd64"` and `supported_arch: ["amd64"]`.
Current add-on arch: amd64
Current BUILD_FROM: ghcr.io/home-assistant/amd64-base:3.21
```

Before keeping `arch: [amd64]` and `ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21`, verify Daisy's actual add-on architecture is `amd64`. If Daisy uses a different architecture, update both `arch` and `BUILD_FROM` in the same commit and document the observed architecture here and in the PR body.

## Trusted Network Exposure

Verify the bridge is reachable only over the HAL9000/NerveCenter trusted Tailnet or another trusted network path where possible.

If Home Assistant OS or firewall controls cannot restrict exposure further, document that limitation here and rely on these compensating controls: random bridge token, read-only `GET /health`, no mutating endpoints, no add-on logs, default-deny sanitization, and sanitized `401`/`404`/`405`/`500`/`502` responses.

HAL9000 health check:

```bash
curl -fsS -H "Authorization: Bearer $DAISY_SUPERVISOR_BRIDGE_TOKEN" http://100.103.249.3:9567/health
```

Unauthorized check:

```bash
curl -i -H "Authorization: Bearer invalid-token" http://100.103.249.3:9567/health
```

## HAL9000 Verification

Before marking deployment ready:

1. Confirm the bridge starts on Daisy without logging raw options or Supervisor responses.
2. Run the authenticated health check from HAL9000 or NerveCenter.
3. Confirm invalid authentication returns a sanitized `401`.
4. Confirm no add-on logs, raw option maps, passwords, usernames, Supervisor tokens, or request headers appear in the response.
5. Confirm NUT config is summarized as booleans and counts only.

## Manual Acceptance on Daisy

- [ ] Bridge add-on config contains `ports: {"9567/tcp": 9567}` and `host_network: false`.
- [ ] Daisy's actual Home Assistant add-on architecture has replaced the `pending` value in the Architecture gate above before this item is checked; if Daisy reports an architecture other than `amd64`, this commit updates both `arch` and `BUILD_FROM` and records the observed architecture.
- [ ] The local add-on installs and starts successfully on Daisy with the committed manifest/Dockerfile.
- [ ] Bridge command is wrapped with `/command/with-contenv` so injected Supervisor environment variables are visible at runtime.
- [ ] Bridge refuses to start with a blank token.
- [ ] Bridge starts with a random 64 hex character token from `openssl rand -hex 32`.
- [ ] `GET /health` with a valid token returns `a0d7b954_nut`.
- [ ] `GET /health` with an invalid token returns `401` and `{"error":"unauthorized"}`.
- [ ] Response JSON does not contain raw `options.users[].password`.
- [ ] `hassio_role: manager` can read `/addons`, `/addons/a0d7b954_nut/info`, and `/supervisor/info`; `default` returned `403` for `/addons` on Daisy.
- [ ] HAL9000 can reach `http://100.103.249.3:9567/health` over the trusted Tailnet path.
- [ ] Bridge reachability is limited to the HAL9000/NerveCenter trusted Tailnet or trusted network path where HA OS/firewall controls allow it.
- [ ] If HA OS/firewall controls cannot restrict exposure further in this environment, this README records that limitation and the compensating controls: random bridge token, read-only `GET /health`, no mutating endpoints, no add-on logs, and sanitized responses.

## Acceptance After Daisy NUT Is Fixed

- [ ] Bridge valid-token `/health` returns `a0d7b954_nut.state == "started"`.
- [ ] NerveCenter `/sources/daisy/ha_supervisor` returns to `:ok`.
- [ ] A `ha_supervisor_addon_recovered` recovery event is recorded.
- [ ] Daisy returns to `:ok` when other Daisy sources are also `:ok`.
- [ ] Existing `/sources/ups/nut` remains healthy.
- [ ] `/metrics` still exports KITT UPS metrics.

## Failure Modes

Missing or invalid add-on options stop startup with a sanitized configuration error.

Supervisor authorization failures and malformed Supervisor responses return:

```json
{"error":"supervisor_unavailable"}
```

Unexpected bridge handler failures return:

```json
{"error":"bridge_error"}
```

If one watched add-on's detail endpoint is unavailable after `/addons` succeeds, `/health` still returns `200` with that add-on marked `state: unknown`, `available: false`, and a sanitized warning.
