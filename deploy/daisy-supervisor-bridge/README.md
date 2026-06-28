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
4. Confirm the add-on installs, starts, binds `9567/tcp`, and runs with direct `CMD` plus `init: false`.
5. If the Home Assistant add-on validator rejects direct `CMD` or `init: false`, convert the add-on to an S6 service layout before proceeding.

## Required Options

`token` must be a random value of at least 32 characters and must not be the documented example value.

`watched_addons` must contain the add-on slugs to summarize. The initial Daisy target is:

```text
a0d7b954_nut
```

## Role Verification

`hassio_role: default` is the initial target, not an immutable requirement. Verify the role on Daisy against all three Supervisor endpoints before relying on the bridge:

```text
/addons
/addons/a0d7b954_nut/info
/supervisor/info
```

Role gate:

```text
Endpoint                         Observed status  Selected role
/addons                          pending          default
/addons/a0d7b954_nut/info         pending          default
/supervisor/info                  pending          default
```

If any endpoint fails, raise only to the least Home Assistant Supervisor role that works, update `config.yaml`, and record the endpoint, observed status code, and selected role here and in the PR body.

Architecture gate:

```text
Observed Daisy add-on architecture: pending
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
