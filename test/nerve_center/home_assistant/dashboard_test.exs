defmodule NerveCenter.HomeAssistant.DashboardTest do
  use NerveCenter.DataCase, async: false

  alias NerveCenter.HomeAssistant.Dashboard

  test "creates and updates dashboard cards" do
    assert {:ok, card} =
             Dashboard.create_card(:daisy, %{
               "entity_id" => "sensor.test_temperature",
               "title" => "Temperature",
               "card_type" => "sensor",
               "size" => "medium"
             })

    assert [saved] = Dashboard.list_cards(:daisy)
    assert saved.id == card.id
    assert saved.title == "Temperature"

    assert {:ok, updated} = Dashboard.update_card(saved, %{"title" => "Office", "size" => "wide"})
    assert updated.title == "Office"
    assert updated.size == "wide"

    assert {:ok, _deleted} = Dashboard.delete_card(updated)
    assert Dashboard.list_cards(:daisy) == []
  end

  test "allows multiple cards for the same entity" do
    attrs = %{
      "entity_id" => "sensor.test_temperature",
      "title" => "Temperature",
      "card_type" => "sensor",
      "size" => "medium"
    }

    assert {:ok, _card} = Dashboard.create_card(:daisy, attrs)
    assert {:ok, _card} = Dashboard.create_card(:daisy, attrs)

    assert length(Dashboard.list_cards(:daisy)) == 2
  end
end
