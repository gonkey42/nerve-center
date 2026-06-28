defmodule NerveCenter.Runtime.PreflightTest do
  use ExUnit.Case, async: false

  alias NerveCenter.Paths
  alias NerveCenter.Runtime.Preflight
  alias NerveCenter.Topology

  test "required env only includes enabled source env" do
    required_env = Preflight.required_env()

    assert "SECRET_KEY_BASE" in required_env
    assert "RELEASE_COOKIE" in required_env
    assert "PLEX_TOKEN" in required_env

    assert "PIHOLE_APP_PASSWORD" in required_env
    assert "NUT_USERNAME" in required_env
    assert "NUT_PASSWORD" in required_env
    assert "IMMICH_API_KEY" in required_env
    assert "HA_TOKEN" in required_env
    assert "DAISY_SUPERVISOR_BRIDGE_TOKEN" in required_env
    assert "UNIFI_API_KEY" in required_env
  end

  test "daisy supervisor bridge config lives on the device" do
    daisy = Topology.get_device!(:daisy)
    supervisor_source = Enum.find(daisy.sources, &(&1.name == :ha_supervisor))

    assert daisy.supervisor_bridge_base_url == "http://127.0.0.1:9567"

    assert daisy.supervisor_addons == [
             %{
               slug: "a0d7b954_nut",
               label: "Network UPS Tools",
               required: true,
               expected_states: ["started"],
               config_checks: [:nut_addon]
             }
           ]

    assert supervisor_source == %{
             name: :ha_supervisor,
             module: NerveCenter.Sources.Daisy.HASupervisorSource,
             enabled: true,
             interval_ms: 60_000
           }
  end

  test "verify! raises and writes to the boot log when a required env is missing" do
    log_path = Paths.app_log_path()
    File.rm(log_path)

    previous = System.get_env("SECRET_KEY_BASE")
    System.delete_env("SECRET_KEY_BASE")

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("SECRET_KEY_BASE")
      else
        System.put_env("SECRET_KEY_BASE", previous)
      end
    end)

    assert_raise RuntimeError, ~r/missing required env: SECRET_KEY_BASE/, fn ->
      Preflight.verify!()
    end

    assert File.read!(log_path) =~ "missing required env: SECRET_KEY_BASE"
  end
end
