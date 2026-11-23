# Building and deploying NerveCenter

NerveCenter runs on the Mac as a Mix release, started by the launch agent `com.claudebot.nerve-center` through `deploy/nervecenter-launch`. These steps were last run on 22 Nov 2026 (Elixir 1.20, Erlang/OTP 29).

All commands run from the repository root of the live checkout, on `main`.

## 1. Get the code

```sh
git fetch origin
git merge --ff-only origin/main
```

## 2. Build beside the running release

Build into a second folder so the running service is not touched until the swap.

```sh
export MIX_ENV=prod
mix deps.get --only prod
mix assets.setup
mix compile
mix assets.deploy
mix release --path _build/prod/rel/nerve_center.new
```

No secrets are needed to build. `config/runtime.exs` is read when the release starts, not when it is built.

### If `mix assets.deploy` fails with "exited with 137"

macOS kills the downloaded Tailwind binary when its code signature is invalid. Re-sign it locally (no password needed), then run `mix assets.deploy` again:

```sh
codesign --force --sign - _build/tailwind-macos-arm64
```

Do not skip this. If the asset step fails, `mix release` still succeeds and packs whatever is in `priv/static`, which can be an old stylesheet.

## 3. Check the new release before the swap

The stylesheet and script named in the new release's `cache_manifest.json` must exist, and after a change that does not touch `assets/` they should be the same files the running release serves:

```sh
grep -o '"assets/css/app.css":"[^"]*"' _build/prod/rel/nerve_center.new/lib/nerve_center-*/priv/static/cache_manifest.json
grep -o '"assets/css/app.css":"[^"]*"' _build/prod/rel/nerve_center/lib/nerve_center-*/priv/static/cache_manifest.json
```

## 4. Swap and restart

```sh
cd _build/prod/rel
mv nerve_center nerve_center.pre-$(date +%Y%m%d)
mv nerve_center.new nerve_center
launchctl kickstart -k gui/$(id -u)/com.claudebot.nerve-center
```

The dashboard is down for a few seconds. On start the app writes one database backup, runs migrations, then removes older backups (it keeps the newest `NERVE_CENTER_BACKUP_KEEP`, default 1).

## 5. Verify

- `launchctl list | grep nerve-center` shows a process id and exit status 0.
- The dashboard answers on port 4041.
- The backup folder holds one fresh `nerve_center-<timestamp>.sqlite3`.
- The app log shows `Access NerveCenterWeb.Endpoint` with no errors after it.

## Roll back

```sh
cd _build/prod/rel
mv nerve_center nerve_center.bad
mv nerve_center.pre-<date> nerve_center
launchctl kickstart -k gui/$(id -u)/com.claudebot.nerve-center
```

Old `nerve_center.pre-*` folders can be removed once the new release has run for a few days.

## Launch agent and secrets

`deploy/com.claudebot.nerve-center.plist.template` documents the launch agent. The launcher reads every secret from the login Keychain at start; nothing secret lives in this repository or in the plist. After changing the plist itself, use `launchctl bootout` and `launchctl bootstrap` instead of `kickstart`.
