defmodule NerveCenter.TopologyTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Topology

  test "HAL9000 launchd dashboard services only include active services with display names" do
    assert Topology.get_device!(:hal9000).launchd_labels == [
             %{label: "com.claudebot.youtube-ripper", display_name: "YouTube Ripper"},
             %{label: "com.spendsense.app", display_name: "SpendSense"},
             %{label: "com.claudebot.nerve-center", display_name: "Nerve Center"}
           ]
  end
end
