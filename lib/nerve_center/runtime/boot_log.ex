defmodule NerveCenter.Runtime.BootLog do
  @moduledoc false

  alias NerveCenter.Paths

  def append!(message) do
    File.mkdir_p!(Paths.log_dir())

    line =
      [
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        " ",
        message,
        "\n"
      ]

    File.write!(Paths.app_log_path(), line, [:append])
  end
end
