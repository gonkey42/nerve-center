defmodule NerveCenterWeb.DeviceLive do
  use NerveCenterWeb, :live_view

  alias NerveCenter.Messages.AppHealthUpdated
  alias NerveCenter.Messages.DeviceSnapshotUpdated
  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Topology
  alias NerveCenterWeb.Display

  @impl true
  def mount(%{"id" => device_id}, _session, socket) do
    device = Topology.get_device!(device_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    end

    {:ok,
     assign(socket,
       page_title: "#{device.label} Device",
       device: device,
       snapshot: SnapshotStore.snapshot(device.id),
       health: AppHealth.snapshot()
     )}
  end

  @impl true
  def handle_info(%DeviceSnapshotUpdated{snapshot: snapshot}, socket) do
    {:noreply, assign(socket, :snapshot, snapshot)}
  end

  def handle_info(%AppHealthUpdated{health: health}, socket) do
    {:noreply, assign(socket, :health, health)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-screen max-w-7xl flex-col gap-8 px-6 py-10 lg:px-10">
      <header class="flex flex-col gap-3 border-b border-stone-800 pb-6">
        <p class="text-xs uppercase tracking-[0.35em] text-amber-300">Device</p>
        <div class="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h1 class="text-4xl font-semibold tracking-tight text-stone-50">{@device.label}</h1>
            <p class="mt-2 max-w-2xl text-sm text-stone-300">
              Current snapshot, metrics, and source state for {@device.hostname}.
            </p>
          </div>
          <nav class="flex gap-3 text-sm">
            <.link
              navigate={~p"/"}
              class="rounded-full border border-stone-700 px-4 py-2 text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
            >
              Dashboard
            </.link>
            <.link
              navigate={~p"/sources"}
              class="rounded-full border border-stone-700 px-4 py-2 text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
            >
              Sources
            </.link>
          </nav>
        </div>
      </header>

      <section class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <.panel title="Status">
          <span class={[
            "inline-flex rounded-full px-3 py-1 text-sm font-medium ring-1",
            Display.status_class(@snapshot.status)
          ]}>
            {@snapshot.status}
          </span>
        </.panel>
        <.panel title="Hostname" value={@device.hostname} />
        <.panel title="IP" value={@device.ip} />
        <.panel title="Updated At">
          <.utc_time value={@snapshot.updated_at} class="text-lg font-semibold text-stone-50" />
        </.panel>
      </section>

      <section class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Current Metrics</h2>
        </div>
        <div class="grid gap-4 px-6 py-5 md:grid-cols-2 xl:grid-cols-3">
          <div
            :for={{metric_id, value} <- metric_rows(@snapshot.metrics)}
            class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4"
          >
            <p class="text-xs uppercase tracking-[0.22em] text-stone-400">
              {metric_label(metric_id)}
            </p>
            <p class="mt-2 text-lg font-semibold text-stone-50">{Display.metric(metric_id, value)}</p>
          </div>
          <p
            :if={Enum.empty?(metric_rows(@snapshot.metrics))}
            class="px-1 py-2 text-sm text-stone-400"
          >
            No metrics have been recorded yet.
          </p>
        </div>
      </section>

      <section
        :if={preview_entries(@snapshot) != []}
        class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
      >
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Frigate Preview</h2>
        </div>
        <div class="grid gap-4 px-6 py-5 md:grid-cols-2">
          <figure :for={entry <- preview_entries(@snapshot)} class="space-y-3">
            <img
              src={preview_url(entry)}
              alt={"Frigate preview for #{entry.camera_name}"}
              class="h-64 w-full rounded-2xl border border-stone-800 object-cover"
            />
            <figcaption class="flex items-center justify-between text-sm text-stone-300">
              <span>{entry.camera_name}</span>
              <span>{Display.bytes(entry.size_bytes)}</span>
            </figcaption>
          </figure>
        </div>
      </section>

      <section
        :if={ha_entities(@snapshot) != []}
        class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
      >
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Home Assistant Entities</h2>
        </div>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-stone-800 text-sm">
            <thead class="bg-stone-950/70 text-left text-xs uppercase tracking-[0.24em] text-stone-400">
              <tr>
                <th class="px-6 py-3">Entity</th>
                <th class="px-6 py-3">State</th>
                <th class="px-6 py-3">Last Updated</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-800 text-stone-200">
              <tr :for={entity <- ha_entities(@snapshot)}>
                <td class="px-6 py-4">
                  <p class="font-medium text-stone-100">{entity.friendly_name}</p>
                  <p class="text-xs text-stone-500">{entity.entity_id}</p>
                </td>
                <td class="px-6 py-4">{entity_state(entity)}</td>
                <td class="px-6 py-4">
                  <.utc_time value={entity.last_updated} class="text-stone-300" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="grid gap-6 xl:grid-cols-2">
        <article
          :for={source <- enabled_sources(@device)}
          class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
        >
          <% source_snapshot = Map.get(@snapshot.sources, source.name) %>
          <% source_health = @health.sources[{@device.id, source.name}] %>
          <div class="flex items-start justify-between gap-4 border-b border-stone-800 px-6 py-4">
            <div>
              <h2 class="text-lg font-semibold text-stone-50">{Display.source_name(source)}</h2>
              <p class="mt-1 text-sm text-stone-400">Collector</p>
            </div>
            <.link
              navigate={source_path(@device.id, source.name)}
              class="rounded-full border border-stone-700 px-4 py-2 text-xs text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
            >
              Source Detail
            </.link>
          </div>

          <div class="flex flex-col gap-4 px-6 py-5">
            <div class="grid gap-4 sm:grid-cols-2">
              <.kv label="Snapshot Status" value={source_status(source_snapshot)} />
              <.kv label="Interval" value={"#{source.interval_ms} ms"} />
              <.kv label="Last OK">
                <.utc_time value={source_health.last_ok_at} class="text-stone-50" />
              </.kv>
              <.kv label="Backoff" value={"#{source_health.backoff_ms} ms"} />
            </div>

            <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
              <h3 class="text-xs uppercase tracking-[0.22em] text-stone-400">Current Data</h3>
              <div class="mt-3">
                <.data_view source={source} data={(source_snapshot && source_snapshot.data) || %{}} />
              </div>
            </div>
          </div>
        </article>
      </section>
    </main>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, default: nil
  slot :inner_block

  defp panel(assigns) do
    ~H"""
    <div class="rounded-3xl border border-stone-800 bg-stone-900/80 p-5">
      <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@title}</p>
      <div class="mt-3">
        <%= if @value do %>
          <p class="text-lg font-semibold text-stone-50">{@value}</p>
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil
  slot :inner_block

  defp kv(assigns) do
    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
      <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
      <div class="mt-2 text-sm text-stone-50">
        <%= if @value do %>
          {@value}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </div>
    """
  end

  attr :source, :map, required: true
  attr :data, :map, required: true

  defp data_view(%{source: %{name: :launchd}, data: %{services: services}} = assigns)
       when is_list(services) do
    ~H"""
    <div class="space-y-2">
      <div :for={service <- @data.services} class="flex items-center justify-between gap-3 text-sm">
        <span class="truncate text-stone-100">
          {Map.get(service, :display_name) || service.label}
        </span>
        <span class="text-stone-400">{if service.running, do: "running", else: "stopped"}</span>
      </div>
    </div>
    """
  end

  defp data_view(assigns) do
    ~H"""
    <pre class="overflow-x-auto whitespace-pre-wrap text-sm text-stone-200">{pretty(@data)}</pre>
    """
  end

  defp enabled_sources(device), do: Enum.filter(device.sources, & &1.enabled)

  defp source_status(nil), do: "unknown"
  defp source_status(snapshot), do: Atom.to_string(snapshot.status)

  defp metric_rows(metrics) do
    metrics
    |> Enum.sort_by(fn {metric_id, _value} -> metric_label(metric_id) end)
  end

  defp metric_label(metric_id) do
    case Catalog.definition(metric_id) do
      %{id: id} ->
        humanize_metric(id)

      nil ->
        humanize_metric(metric_id)
    end
  end

  defp source_path(device_id, source_name) do
    "/sources/#{device_id}/#{source_name}"
  end

  defp preview_entries(snapshot) do
    get_in(snapshot.sources, [:frigate_preview, Access.key(:data), :entries]) || []
  end

  defp preview_url(entry), do: "#{entry.cache_path}?etag=#{entry.etag}"

  defp ha_entities(snapshot) do
    get_in(snapshot.sources, [:ha_web_socket, Access.key(:data), :entities]) || []
  end

  defp entity_state(%{state: state, unit_of_measurement: nil}), do: state
  defp entity_state(%{state: state, unit_of_measurement: unit}), do: "#{state} #{unit}"

  defp humanize_metric(metric_id) do
    metric_id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp pretty(data), do: inspect(data, pretty: true, limit: :infinity)
end
