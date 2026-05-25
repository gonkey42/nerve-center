defmodule NerveCenter.Sources.Ups.NUTSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @tcp_timeout 5_000

  @impl true
  def required_env, do: ["NUT_USERNAME", "NUT_PASSWORD"]

  @impl true
  def normal_interval_ms, do: 30_000

  @impl true
  def stale_after_ms, do: 90_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       host: context.device.nut_host,
       port: context.device.nut_port,
       ups_name: context.device.nut_device,
       protocol: "NUT TCP text"
     }}
  end

  @impl true
  def poll(context) do
    with_socket(context.device, fn socket ->
      with :ok <- run_auth(socket),
           :ok <- write_command(socket, "LIST VAR #{context.device.nut_device}"),
           {:ok, vars} <- read_var_list(socket, context.device.nut_device),
           :ok <- write_command(socket, "LOGOUT"),
           :ok <- expect_line(socket, "OK Goodbye") do
        {:ok, vars}
      end
    end)
  end

  @impl true
  def normalize(raw, _context) do
    with {:ok, battery_charge} <- fetch_float(raw, "battery.charge"),
         {:ok, battery_runtime} <- fetch_integer(raw, "battery.runtime"),
         {:ok, ups_load} <- fetch_float(raw, "ups.load"),
         {:ok, input_voltage} <- fetch_float(raw, "input.voltage") do
      status = Map.get(raw, "ups.status", "")
      status_tokens = String.split(status, " ", trim: true)
      current_load_watts = current_load_watts(raw, ups_load)

      {:ok,
       %{
         observed_at: DateTime.utc_now(),
         metrics:
           [
             %{metric: :ups_battery_charge_ratio, value: battery_charge / 100},
             %{metric: :ups_battery_runtime_seconds, value: battery_runtime},
             %{metric: :ups_load_ratio, value: ups_load / 100},
             %{metric: :ups_input_voltage_volts, value: input_voltage},
             %{metric: :ups_on_battery_flag, value: flag(status_tokens, "OB")},
             %{metric: :ups_low_battery_flag, value: flag(status_tokens, "LB")}
           ] ++ optional_metric(:ups_current_load_watts, current_load_watts),
         data: %{
           status: status,
           battery_charge_percent: battery_charge,
           battery_runtime_seconds: battery_runtime,
           load_percent: ups_load,
           current_load_watts: current_load_watts,
           input_voltage_volts: input_voltage,
           output_voltage_volts: fetch_optional_float(raw, "output.voltage"),
           battery_voltage_volts: fetch_optional_float(raw, "battery.voltage"),
           model: Map.get(raw, "ups.model") || Map.get(raw, "device.model"),
           manufacturer: Map.get(raw, "ups.mfr") || Map.get(raw, "device.mfr"),
           driver_name: Map.get(raw, "driver.name"),
           driver_version: Map.get(raw, "driver.version"),
           test_result: Map.get(raw, "ups.test.result")
         }
       }}
    end
  end

  defp current_load_watts(raw, ups_load) do
    fetch_optional_float(raw, "ups.realpower") ||
      case fetch_optional_float(raw, "ups.realpower.nominal") do
        nil -> nil
        nominal_watts -> nominal_watts * ups_load / 100
      end
  end

  defp optional_metric(_metric, nil), do: []
  defp optional_metric(metric, value), do: [%{metric: metric, value: value}]

  defp with_socket(device, fun) do
    host = String.to_charlist(device.nut_host)

    case :gen_tcp.connect(
           host,
           device.nut_port,
           [:binary, active: false, packet: :line],
           @tcp_timeout
         ) do
      {:ok, socket} ->
        try do
          fun.(socket)
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, {:tcp_connect, reason}}
    end
  end

  defp run_auth(socket) do
    with :ok <- write_command(socket, "USERNAME #{System.fetch_env!("NUT_USERNAME")}"),
         :ok <- expect_line(socket, "OK"),
         :ok <- write_command(socket, "PASSWORD #{System.fetch_env!("NUT_PASSWORD")}"),
         :ok <- expect_line(socket, "OK") do
      :ok
    end
  end

  defp write_command(socket, command) do
    case :gen_tcp.send(socket, [command, "\r\n"]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tcp_send, reason}}
    end
  end

  defp read_var_list(socket, device_name) do
    begin_line = "BEGIN LIST VAR #{device_name}"
    end_line = "END LIST VAR #{device_name}"

    with :ok <- expect_line(socket, begin_line) do
      do_read_var_list(socket, device_name, end_line, %{})
    end
  end

  defp do_read_var_list(socket, device_name, end_line, acc) do
    with {:ok, line} <- recv_line(socket) do
      cond do
        line == end_line ->
          {:ok, acc}

        String.starts_with?(line, "VAR #{device_name} ") ->
          case parse_var_line(device_name, line) do
            {:ok, {key, value}} ->
              do_read_var_list(socket, device_name, end_line, Map.put(acc, key, value))

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          {:error, {:unexpected_line, line}}
      end
    end
  end

  defp parse_var_line(device_name, line) do
    prefix = "VAR #{device_name} "

    case String.trim_leading(line, prefix) do
      ^line ->
        {:error, {:unexpected_line, line}}

      payload ->
        case String.split(payload, " ", parts: 2) do
          [key, value] ->
            {:ok, {key, strip_quotes(value)}}

          _ ->
            {:error, {:unexpected_line, line}}
        end
    end
  end

  defp strip_quotes(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp expect_line(socket, expected) do
    case recv_line(socket) do
      {:ok, ^expected} ->
        :ok

      {:ok, "ERR " <> message} ->
        {:error, classify_nut_error(message)}

      {:ok, line} ->
        {:error, {:unexpected_line, line}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_line(socket) do
    case :gen_tcp.recv(socket, 0, @tcp_timeout) do
      {:ok, line} ->
        {:ok, String.trim(line)}

      {:error, reason} ->
        {:error, {:tcp_recv, reason}}
    end
  end

  defp classify_nut_error("ACCESS-DENIED" <> _rest = message), do: {:auth, message}
  defp classify_nut_error("USERNAME-REQUIRED" <> _rest = message), do: {:auth, message}
  defp classify_nut_error("PASSWORD-REQUIRED" <> _rest = message), do: {:auth, message}
  defp classify_nut_error(message), do: {:nut_error, message}

  defp fetch_float(vars, key) do
    case Map.fetch(vars, key) do
      {:ok, value} -> {:ok, Support.to_float(value)}
      :error -> {:error, {:missing_var, key}}
    end
  end

  defp fetch_integer(vars, key) do
    case Map.fetch(vars, key) do
      {:ok, value} -> {:ok, Support.to_integer(value)}
      :error -> {:error, {:missing_var, key}}
    end
  end

  defp fetch_optional_float(vars, key) do
    case Map.fetch(vars, key) do
      {:ok, value} -> Support.to_float(value)
      :error -> nil
    end
  end

  defp flag(tokens, token), do: if(token in tokens, do: 1, else: 0)
end
