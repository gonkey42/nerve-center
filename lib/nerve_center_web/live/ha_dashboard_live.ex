defmodule NerveCenterWeb.HADashboardLive do
  use NerveCenterWeb, :live_view

  alias NerveCenter.HomeAssistant.Client
  alias NerveCenter.HomeAssistant.Dashboard
  alias NerveCenter.Messages.DeviceSnapshotUpdated
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Topology
  alias NerveCenterWeb.Display

  @impl true
  def mount(%{"id" => device_id}, _session, socket) do
    device = Topology.get_device!(device_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    end

    snapshot = SnapshotStore.snapshot(device.id)
    entities = load_entities(device, snapshot)

    {:ok,
     assign(socket,
       page_title: "#{device.label} Home Assistant",
       device: device,
       snapshot: snapshot,
       entities: entities,
       cards: Dashboard.ensure_default_cards(device.id, entities),
       query: "",
       selected_entity_id: first_entity_id(entities),
       selected_card_type: "entity",
       selected_size: "medium"
     )}
  end

  @impl true
  def handle_info(%DeviceSnapshotUpdated{snapshot: snapshot}, socket) do
    entities = load_entities(socket.assigns.device, snapshot)

    {:noreply,
     assign(socket,
       snapshot: snapshot,
       entities: merge_entities(socket.assigns.entities, entities),
       cards: Dashboard.list_cards(socket.assigns.device.id)
     )}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :query, query)}
  end

  def handle_event("select-add", %{"entity_id" => entity_id}, socket) do
    {:noreply, assign(socket, :selected_entity_id, entity_id)}
  end

  def handle_event("set-add-options", params, socket) do
    {:noreply,
     assign(socket,
       selected_entity_id:
         normalize_entity_id(Map.get(params, "entity_id"), socket.assigns.selected_entity_id),
       selected_card_type: Map.get(params, "card_type", socket.assigns.selected_card_type),
       selected_size: Map.get(params, "size", socket.assigns.selected_size)
     )}
  end

  def handle_event("add-card", params, socket) do
    entity_id =
      normalize_entity_id(Map.get(params, "entity_id"), socket.assigns.selected_entity_id)

    entity = find_entity(socket.assigns.entities, entity_id)

    attrs = %{
      "entity_id" => entity_id,
      "title" => entity_title(entity, entity_id),
      "card_type" => socket.assigns.selected_card_type,
      "size" => socket.assigns.selected_size
    }

    case entity_id && Dashboard.create_card(socket.assigns.device.id, attrs) do
      {:ok, _card} ->
        {:noreply,
         socket
         |> assign(:cards, Dashboard.list_cards(socket.assigns.device.id))
         |> assign(:selected_entity_id, entity_id)
         |> put_flash(:info, "Card added")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That card is invalid")}

      nil ->
        {:noreply, put_flash(socket, :error, "Choose or enter an entity first")}
    end
  end

  def handle_event("delete-card", %{"id" => id}, socket) do
    card = Dashboard.get_card!(id)
    {:ok, _card} = Dashboard.delete_card(card)

    {:noreply,
     socket
     |> assign(:cards, Dashboard.list_cards(socket.assigns.device.id))
     |> put_flash(:info, "Card removed")}
  end

  def handle_event("update-card", %{"id" => id, "card" => attrs}, socket) do
    card = Dashboard.get_card!(id)

    case Dashboard.update_card(card, attrs) do
      {:ok, _card} ->
        {:noreply,
         socket
         |> assign(:cards, Dashboard.list_cards(socket.assigns.device.id))
         |> put_flash(:info, "Card updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Card update failed")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-screen max-w-7xl flex-col gap-8 px-6 py-10 lg:px-10">
      <header class="flex flex-col gap-3 border-b border-stone-800 pb-6">
        <p class="text-xs uppercase tracking-[0.35em] text-amber-300">Home Assistant</p>
        <div class="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h1 class="text-4xl font-semibold tracking-tight text-stone-50">
              {@device.label} Dashboard
            </h1>
            <p class="mt-2 max-w-2xl text-sm text-stone-300">
              Editable cards backed by the Home Assistant entities from {@device.hostname}.
            </p>
          </div>
          <nav class="flex flex-wrap gap-3 text-sm">
            <.link
              navigate={~p"/devices/#{Atom.to_string(@device.id)}"}
              class="rounded-full border border-stone-700 px-4 py-2 text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
            >
              Device
            </.link>
            <.link
              navigate={~p"/"}
              class="rounded-full border border-stone-700 px-4 py-2 text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
            >
              Dashboard
            </.link>
          </nav>
        </div>
        <div
          :if={Phoenix.Flash.get(@flash, :info) || Phoenix.Flash.get(@flash, :error)}
          class="rounded-2xl border border-stone-800 bg-stone-950/80 px-4 py-3 text-sm"
        >
          <p :if={Phoenix.Flash.get(@flash, :info)} class="text-emerald-200">
            {Phoenix.Flash.get(@flash, :info)}
          </p>
          <p :if={Phoenix.Flash.get(@flash, :error)} class="text-rose-200">
            {Phoenix.Flash.get(@flash, :error)}
          </p>
        </div>
      </header>

      <section class="grid gap-6 xl:grid-cols-[0.85fr_1.15fr]">
        <aside class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">Add Card</h2>
          </div>
          <div class="flex flex-col gap-5 px-6 py-5">
            <form phx-change="search">
              <label class="text-xs uppercase tracking-[0.22em] text-stone-400" for="ha-search">
                Entity Search
              </label>
              <input
                id="ha-search"
                name="query"
                value={@query}
                type="search"
                class="mt-2 w-full rounded-2xl border border-stone-700 bg-stone-950 px-4 py-3 text-sm text-stone-100 outline-none transition focus:border-amber-400/70"
                placeholder="Search entities"
              />
            </form>

            <div class="max-h-80 overflow-y-auto rounded-2xl border border-stone-800 bg-stone-950/70">
              <button
                :for={entity <- filtered_entities(@entities, @query)}
                type="button"
                phx-click="select-add"
                phx-value-entity_id={entity.entity_id}
                class={[
                  "flex w-full items-center justify-between gap-4 border-b border-stone-800 px-4 py-3 text-left text-sm last:border-b-0",
                  if(@selected_entity_id == entity.entity_id,
                    do: "bg-amber-400/10 text-amber-100",
                    else: "text-stone-200 hover:bg-stone-900"
                  )
                ]}
              >
                <span class="min-w-0">
                  <span class="block truncate font-medium">{entity.friendly_name}</span>
                  <span class="block truncate text-xs text-stone-500">{entity.entity_id}</span>
                </span>
                <span class="text-xs text-stone-400">{entity_state(entity)}</span>
              </button>
              <p
                :if={filtered_entities(@entities, @query) == []}
                class="px-4 py-5 text-sm text-stone-400"
              >
                No entities match.
              </p>
            </div>

            <form phx-change="set-add-options" phx-submit="add-card" class="grid gap-4 sm:grid-cols-2">
              <label class="text-sm text-stone-300 sm:col-span-2">
                <span class="text-xs uppercase tracking-[0.22em] text-stone-400">Entity ID</span>
                <input
                  name="entity_id"
                  value={@selected_entity_id || ""}
                  class="mt-2 w-full rounded-2xl border border-stone-700 bg-stone-950 px-3 py-2 text-sm text-stone-100"
                  placeholder="sensor.example"
                />
              </label>
              <label class="text-sm text-stone-300">
                <span class="text-xs uppercase tracking-[0.22em] text-stone-400">Type</span>
                <select
                  name="card_type"
                  class="mt-2 w-full rounded-2xl border border-stone-700 bg-stone-950 px-3 py-2 text-sm text-stone-100"
                >
                  <option
                    :for={type <- card_types()}
                    value={type}
                    selected={type == @selected_card_type}
                  >
                    {Display.humanize(type)}
                  </option>
                </select>
              </label>
              <label class="text-sm text-stone-300">
                <span class="text-xs uppercase tracking-[0.22em] text-stone-400">Size</span>
                <select
                  name="size"
                  class="mt-2 w-full rounded-2xl border border-stone-700 bg-stone-950 px-3 py-2 text-sm text-stone-100"
                >
                  <option :for={size <- card_sizes()} value={size} selected={size == @selected_size}>
                    {Display.humanize(size)}
                  </option>
                </select>
              </label>
              <button
                type="submit"
                class="rounded-full border border-amber-400/50 px-4 py-2 text-sm font-medium text-amber-100 transition hover:bg-amber-400/10 sm:col-span-2"
              >
                Add Selected Entity
              </button>
            </form>
          </div>
        </aside>

        <section class="grid auto-rows-min gap-4 md:grid-cols-2">
          <article
            :for={card <- @cards}
            class={[
              "overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80",
              card_size_class(card.size)
            ]}
          >
            <% entity = find_entity(@entities, card.entity_id) %>
            <div class="border-b border-stone-800 px-5 py-4">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <p class="text-xs uppercase tracking-[0.22em] text-stone-400">
                    {Display.humanize(card.card_type)}
                  </p>
                  <h2 class="mt-2 truncate text-xl font-semibold text-stone-50">{card.title}</h2>
                  <p class="mt-1 truncate text-xs text-stone-500">{card.entity_id}</p>
                </div>
                <button
                  type="button"
                  phx-click="delete-card"
                  phx-value-id={card.id}
                  data-confirm={"Remove #{card.title}?"}
                  class="rounded-full border border-stone-700 px-3 py-1 text-xs text-stone-300 transition hover:border-rose-400/60 hover:text-rose-100"
                >
                  Remove
                </button>
              </div>
            </div>

            <div class="px-5 py-5">
              <.card_body card={card} entity={entity} />

              <form
                phx-submit="update-card"
                phx-value-id={card.id}
                class="mt-5 grid gap-3 sm:grid-cols-2"
              >
                <input
                  name="card[title]"
                  value={card.title}
                  class="rounded-2xl border border-stone-700 bg-stone-950 px-3 py-2 text-sm text-stone-100 sm:col-span-2"
                  placeholder="Card title"
                />
                <select
                  name="card[card_type]"
                  class="rounded-2xl border border-stone-700 bg-stone-950 px-3 py-2 text-sm text-stone-100"
                >
                  <option :for={type <- card_types()} value={type} selected={type == card.card_type}>
                    {Display.humanize(type)}
                  </option>
                </select>
                <select
                  name="card[size]"
                  class="rounded-2xl border border-stone-700 bg-stone-950 px-3 py-2 text-sm text-stone-100"
                >
                  <option :for={size <- card_sizes()} value={size} selected={size == card.size}>
                    {Display.humanize(size)}
                  </option>
                </select>
                <button
                  type="submit"
                  class="rounded-full border border-stone-700 px-3 py-2 text-xs text-stone-300 transition hover:border-amber-400/60 hover:text-amber-100 sm:col-span-2"
                >
                  Save Card
                </button>
              </form>
            </div>
          </article>

          <p
            :if={@cards == []}
            class="rounded-3xl border border-stone-800 bg-stone-900/80 p-6 text-sm text-stone-400"
          >
            Add a Home Assistant entity to start building this dashboard.
          </p>
        </section>
      </section>
    </main>
    """
  end

  attr :card, :map, required: true
  attr :entity, :map, default: nil

  defp card_body(assigns) do
    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-5">
      <%= if @entity do %>
        <div class="flex items-end justify-between gap-4">
          <div>
            <p class="text-sm text-stone-400">{@entity.friendly_name}</p>
            <p class="mt-2 text-4xl font-semibold text-stone-50">{entity_state(@entity)}</p>
          </div>
          <span class={[
            "rounded-full px-3 py-1 text-xs ring-1",
            entity_state_class(@entity.state)
          ]}>
            {@entity.state}
          </span>
        </div>
        <p :if={@entity.last_updated} class="mt-4 text-xs text-stone-500">
          Updated <.utc_time value={@entity.last_updated} />
        </p>
      <% else %>
        <p class="text-sm text-stone-400">Waiting for this entity from Home Assistant.</p>
      <% end %>
    </div>
    """
  end

  defp load_entities(device, snapshot) do
    case Client.list_states(device) do
      {:ok, entities} -> Enum.sort_by(entities, & &1.friendly_name)
      {:error, _reason} -> fallback_entities(device, snapshot)
    end
  end

  defp ha_entities(snapshot) do
    get_in(snapshot.sources, [:ha_web_socket, Access.key(:data), :entities]) || []
  end

  defp fallback_entities(device, snapshot) do
    case ha_entities(snapshot) do
      [] -> curated_entities(device)
      entities -> entities
    end
  end

  defp curated_entities(device) do
    device
    |> Map.get(:curated_entity_ids, [])
    |> Enum.map(fn entity_id ->
      %{
        entity_id: entity_id,
        friendly_name: entity_id |> String.split(".") |> List.last() |> Display.humanize(),
        state: "unknown",
        unit_of_measurement: nil,
        device_class: nil,
        icon: nil,
        last_updated: nil
      }
    end)
  end

  defp merge_entities(existing, incoming) do
    (existing ++ incoming)
    |> Map.new(&{&1.entity_id, &1})
    |> Map.values()
    |> Enum.sort_by(& &1.friendly_name)
  end

  defp filtered_entities(entities, query) do
    query = String.downcase(String.trim(query || ""))

    Enum.filter(entities, fn entity ->
      query == "" or
        String.contains?(String.downcase(entity.friendly_name), query) or
        String.contains?(String.downcase(entity.entity_id), query)
    end)
  end

  defp find_entity(entities, entity_id), do: Enum.find(entities, &(&1.entity_id == entity_id))

  defp first_entity_id([entity | _entities]), do: entity.entity_id
  defp first_entity_id([]), do: nil

  defp entity_title(nil, entity_id), do: entity_id
  defp entity_title(entity, _entity_id), do: entity.friendly_name

  defp normalize_entity_id(nil, fallback), do: fallback

  defp normalize_entity_id(value, fallback) do
    case String.trim(value) do
      "" -> fallback
      entity_id -> entity_id
    end
  end

  defp entity_state(%{state: state, unit_of_measurement: nil}), do: state
  defp entity_state(%{state: state, unit_of_measurement: unit}), do: "#{state} #{unit}"

  defp entity_state_class("on"), do: "bg-emerald-500/20 text-emerald-200 ring-emerald-400/30"
  defp entity_state_class("off"), do: "bg-stone-700/40 text-stone-300 ring-stone-500/40"
  defp entity_state_class("unavailable"), do: "bg-rose-500/20 text-rose-200 ring-rose-400/30"
  defp entity_state_class(_state), do: "bg-amber-500/20 text-amber-100 ring-amber-400/30"

  defp card_types, do: ["entity", "gauge", "sensor", "weather"]
  defp card_sizes, do: ["small", "medium", "wide"]

  defp card_size_class("small"), do: "md:col-span-1"
  defp card_size_class("wide"), do: "md:col-span-2"
  defp card_size_class(_size), do: "md:col-span-1"
end
