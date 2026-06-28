import Config

for {key, value} <- [
      {"SECRET_KEY_BASE", "test-secret-key-base"},
      {"RELEASE_COOKIE", "test-release-cookie"},
      {"PLEX_TOKEN", "test-plex-token"},
      {"PIHOLE_APP_PASSWORD", "test-pihole-password"},
      {"NUT_USERNAME", "test-nut-user"},
      {"NUT_PASSWORD", "test-nut-password"},
      {"IMMICH_API_KEY", "test-immich-api-key"},
      {"HA_TOKEN", "test-ha-token"},
      {"DAISY_SUPERVISOR_BRIDGE_TOKEN", "test-daisy-supervisor-bridge-token-123456"},
      {"UNIFI_API_KEY", "test-unifi-api-key"}
    ] do
  if is_nil(System.get_env(key)) do
    System.put_env(key, value)
  end
end

devices =
  :nerve_center
  |> Application.get_env(:devices, [])
  |> then(fn
    [] ->
      __DIR__
      |> Path.join("devices.exs")
      |> Config.Reader.read!()
      |> get_in([:nerve_center, :devices])

    devices ->
      devices
  end)
  |> Enum.map(fn
    %{id: :daisy} = device ->
      sources =
        Enum.map(device.sources, fn
          %{name: :ha_supervisor} = source ->
            %{source | supervisor_bridge_base_url: "http://127.0.0.1:9567"}

          source ->
            source
        end)

      %{device | supervisor_bridge_base_url: "http://127.0.0.1:9567", sources: sources}

    device ->
      device
  end)

config :nerve_center, :devices, devices

config :nerve_center, :paths,
  db: Path.expand("../tmp/test/nerve_center.sqlite3", __DIR__),
  backups: Path.expand("../tmp/test/backups", __DIR__),
  log_dir: Path.expand("../tmp/test/logs", __DIR__),
  app_log: Path.expand("../tmp/test/logs/app.log", __DIR__)

config :nerve_center, :allow_unknown_runtime_devices, true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :nerve_center, NerveCenter.Repo,
  database: Path.expand("../tmp/test/nerve_center.sqlite3", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  synchronous: :normal,
  busy_timeout: 5_000,
  foreign_keys: :on,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nerve_center, NerveCenterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4042],
  secret_key_base: "lL8IyPkPj9EqZgAYcyXRgKQNlR+CvayUmk7UB+7PeoQAWDKi3Mh+h6r68Grg2m8a",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
