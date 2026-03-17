defmodule NerveCenter.Sources.Ups.NUTSourceTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Sources.Ups.NUTSource

  setup do
    previous = %{
      "NUT_USERNAME" => System.get_env("NUT_USERNAME"),
      "NUT_PASSWORD" => System.get_env("NUT_PASSWORD")
    }

    System.put_env("NUT_USERNAME", "test-user")
    System.put_env("NUT_PASSWORD", "test-pass")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "poll authenticates, lists vars, and closes the socket per poll" do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        commands = [
          recv_command(socket),
          recv_command(socket),
          recv_command(socket),
          recv_command(socket)
        ]

        assert commands == [
                 "USERNAME test-user",
                 "PASSWORD test-pass",
                 "LIST VAR cyberpower",
                 "LOGOUT"
               ]

        :ok = :gen_tcp.close(socket)
        :ok = :gen_tcp.close(listener)
      end)

    context = %{device: %{nut_host: "127.0.0.1", nut_port: port, nut_device: "cyberpower"}}

    assert {:ok, vars} = NUTSource.poll(context)
    assert vars["battery.charge"] == "100"
    assert vars["battery.runtime"] == "1025"
    assert vars["ups.status"] == "OL"

    Task.await(server)
  end

  test "normalize maps the native NUT text response into canonical metrics" do
    assert {:ok, payload} =
             NUTSource.normalize(
               %{
                 "battery.charge" => "100",
                 "battery.runtime" => "1025",
                 "ups.load" => "30",
                 "input.voltage" => "122.0",
                 "output.voltage" => "122.0",
                 "battery.voltage" => "14.2",
                 "ups.status" => "OL",
                 "ups.model" => "SL900UC",
                 "ups.mfr" => "CPS",
                 "driver.name" => "usbhid-ups",
                 "driver.version" => "2.8.1",
                 "ups.test.result" => "Done and passed"
               },
               %{}
             )

    metrics = Map.new(payload.metrics, &{&1.metric, &1.value})

    assert metrics.ups_battery_charge_ratio == 1.0
    assert metrics.ups_battery_runtime_seconds == 1025
    assert metrics.ups_load_ratio == 0.3
    assert metrics.ups_input_voltage_volts == 122.0
    assert metrics.ups_on_battery_flag == 0
    assert metrics.ups_low_battery_flag == 0
    assert payload.data.status == "OL"
  end

  defp recv_command(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
    trimmed = String.trim(line)

    response =
      case trimmed do
        "USERNAME test-user" ->
          "OK\r\n"

        "PASSWORD test-pass" ->
          "OK\r\n"

        "LIST VAR cyberpower" ->
          [
            "BEGIN LIST VAR cyberpower\r\n",
            "VAR cyberpower battery.charge \"100\"\r\n",
            "VAR cyberpower battery.runtime \"1025\"\r\n",
            "VAR cyberpower ups.status \"OL\"\r\n",
            "END LIST VAR cyberpower\r\n"
          ]

        "LOGOUT" ->
          "OK Goodbye\r\n"
      end

    :ok = :gen_tcp.send(socket, response)
    trimmed
  end
end
