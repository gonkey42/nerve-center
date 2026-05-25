defmodule NerveCenter.TopologyTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Topology

  test "dashboard display order places Rosie, Daisy, Stig, and UPS in requested slots" do
    ordered_ids = Enum.map(Topology.display_devices(), & &1.id)

    assert Enum.slice(ordered_ids, 2, 4) == [:rosie, :daisy, :stig, :ups]
  end

  test "HAL9000 launchd dashboard services only include active services with display names" do
    assert Topology.get_device!(:hal9000).launchd_labels == [
             %{label: "com.claudebot.youtube-ripper", display_name: "YouTube Ripper"},
             %{label: "com.spendsense.app", display_name: "SpendSense"},
             %{label: "com.claudebot.nerve-center", display_name: "Nerve Center"}
           ]
  end
end
