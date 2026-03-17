import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/nerve_center start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :nerve_center, NerveCenterWeb.Endpoint, server: true
end

if config_env() == :prod do
  data_dir =
    System.get_env("NERVE_CENTER_DATA_DIR") || "/Users/hal9000/claudebot/data/nerve-center"

  db_path =
    System.get_env("NERVE_CENTER_DB_PATH") || Path.join(data_dir, "nerve_center.sqlite3")

  backup_dir =
    System.get_env("NERVE_CENTER_BACKUP_DIR") || Path.join(data_dir, "backups")

  app_log =
    System.get_env("NERVE_CENTER_APP_LOG") ||
      Path.join(
        System.get_env("NERVE_CENTER_LOG_DIR") || "/Users/hal9000/claudebot/logs/nerve-center",
        "app.log"
      )

  log_dir = System.get_env("NERVE_CENTER_LOG_DIR") || Path.dirname(app_log)
  public_host = System.get_env("PUBLIC_HOST") || ""
  secret_key_base = System.get_env("SECRET_KEY_BASE") || ""
  release_cookie = System.get_env("RELEASE_COOKIE") || ""

  config :nerve_center, :paths,
    db: db_path,
    backups: backup_dir,
    log_dir: log_dir,
    app_log: app_log

  config :nerve_center, NerveCenter.Repo,
    database: db_path,
    journal_mode: :wal,
    synchronous: :normal,
    busy_timeout: 5_000,
    foreign_keys: :on,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  config :nerve_center, :release_cookie, release_cookie

  config :logger, :default_handler,
    config: [
      file: String.to_charlist(app_log),
      max_no_bytes: 10_485_760,
      max_no_files: 5,
      filesync_repeat_interval: 5_000
    ]

  config :nerve_center, NerveCenterWeb.Endpoint,
    url: [host: public_host, port: 443, scheme: "https"],
    http: [
      ip: {127, 0, 0, 1},
      port: 4041
    ],
    secret_key_base: secret_key_base
end
