defmodule NerveCenter.Runtime.PreflightTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.Preflight

  test "required env only includes enabled source env" do
    required_env = Preflight.required_env()

    assert "SECRET_KEY_BASE" in required_env
    assert "RELEASE_COOKIE" in required_env
    assert "PUBLIC_HOST" in required_env
    assert "PLEX_TOKEN" in required_env

    assert "PIHOLE_APP_PASSWORD" in required_env
    assert "NUT_USERNAME" in required_env
    assert "NUT_PASSWORD" in required_env
    refute "IMMICH_API_KEY" in required_env
    refute "HA_TOKEN" in required_env
    refute "UNIFI_API_KEY" in required_env
  end
end
