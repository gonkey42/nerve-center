defmodule NerveCenter.Runtime.Preflight do
  @moduledoc false

  alias NerveCenter.Runtime.BootLog
  alias NerveCenter.Topology

  @global_required_env ["SECRET_KEY_BASE", "RELEASE_COOKIE"]

  def verify! do
    missing =
      required_env()
      |> Enum.reject(&present?(&1))

    case missing do
      [] ->
        :ok

      vars ->
        message = "missing required env: #{Enum.join(vars, ", ")}"
        BootLog.append!(message)
        raise RuntimeError, message
    end
  end

  def required_env do
    source_env =
      Topology.enabled_sources()
      |> Enum.flat_map(fn {_device, source} -> source.module.required_env() end)

    (@global_required_env ++ source_env)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp present?(var) do
    case System.get_env(var) do
      nil -> false
      "" -> false
      value -> String.trim(value) != ""
    end
  end
end
