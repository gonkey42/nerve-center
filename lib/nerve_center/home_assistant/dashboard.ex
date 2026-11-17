defmodule NerveCenter.HomeAssistant.Dashboard do
  @moduledoc false

  import Ecto.Query

  alias NerveCenter.Persistence.HADashboardCard
  alias NerveCenter.Repo

  def list_cards(device_id) do
    device_id = Atom.to_string(device_id)

    HADashboardCard
    |> where([card], card.device_id == ^device_id)
    |> order_by([card], asc: card.position, asc: card.id)
    |> Repo.all()
  end

  def ensure_default_cards(device_id, entities) do
    case list_cards(device_id) do
      [] ->
        entities
        |> Enum.with_index()
        |> Enum.each(fn {entity, index} ->
          create_card(device_id, %{
            "entity_id" => entity.entity_id,
            "title" => entity.friendly_name,
            "card_type" => default_card_type(entity),
            "size" => "medium",
            "position" => index
          })
        end)

        list_cards(device_id)

      cards ->
        cards
    end
  end

  def create_card(device_id, attrs) do
    position = next_position(device_id)

    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("device_id", Atom.to_string(device_id))
      |> Map.put_new("position", position)
      |> Map.put_new("size", "medium")
      |> Map.put_new("card_type", "entity")
      |> Map.put_new("title", Map.get(attrs, "entity_id") || Map.get(attrs, :entity_id))

    %HADashboardCard{}
    |> HADashboardCard.changeset(attrs)
    |> Repo.insert()
  end

  def update_card(%HADashboardCard{} = card, attrs) do
    card
    |> HADashboardCard.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  def delete_card(%HADashboardCard{} = card), do: Repo.delete(card)

  def get_card!(id), do: Repo.get!(HADashboardCard, id)

  defp next_position(device_id) do
    device_id = Atom.to_string(device_id)

    max_position =
      HADashboardCard
      |> where([card], card.device_id == ^device_id)
      |> select([card], max(card.position))
      |> Repo.one()

    (max_position || -1) + 1
  end

  defp default_card_type(%{entity_id: "weather." <> _rest}), do: "weather"
  defp default_card_type(%{unit_of_measurement: unit}) when is_binary(unit), do: "sensor"
  defp default_card_type(_entity), do: "entity"

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
