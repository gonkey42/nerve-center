defmodule NerveCenter.Repo do
  use Ecto.Repo,
    otp_app: :nerve_center,
    adapter: Ecto.Adapters.SQLite3
end
