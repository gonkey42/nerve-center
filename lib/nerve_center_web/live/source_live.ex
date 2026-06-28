defmodule NerveCenterWeb.SourceLive do
  use NerveCenterWeb, :live_view

  alias NerveCenter.Messages.AppHealthUpdated
  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Topology
  alias NerveCenterWeb.Display

  @impl true
  def mount(%{"device_id" => device_id, "source" => source_name}, _session, socket) do
    device = Topology.get_device!(device_id)
    source = Topology.get_source!(device.id, source_name)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source.name))
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    end

    {:ok,
     assign(socket,
       page_title: "#{device.label} #{Display.source_name(source)}",
       device: device,
       source: source,
       source_snapshot: current_source_snapshot(device.id, source.name),
       source_health: AppHealth.source_state(device.id, source.name)
     )}
  end

  @impl true
  def handle_info(%SourceSnapshotUpdated{source_snapshot: source_snapshot}, socket) do
    {:noreply, assign(socket, :source_snapshot, source_snapshot)}
  end

  def handle_info(%AppHealthUpdated{health: health}, socket) do
    source_health = health.sources[{socket.assigns.device.id, socket.assigns.source.name}]
    {:noreply, assign(socket, :source_health, source_health)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-screen max-w-7xl flex-col gap-8 px-6 py-10 lg:px-10">
      <header class="flex flex-col gap-3 border-b border-stone-800 pb-6">
        <p class="text-xs uppercase tracking-[0.35em] text-amber-300">Source</p>
        <div class="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h1 class="text-4xl font-semibold tracking-tight text-stone-50">
              {@device.label} / {Display.source_name(@source)}
            </h1>
            <p class="mt-2 max-w-2xl text-sm text-stone-300">
              Probe data, current snapshot, and failure state for {Display.source_name(@source)}.
            </p>
          </div>
          <nav class="flex gap-3 text-sm">
            <.link
              navigate={~p"/devices/#{Atom.to_string(@device.id)}"}
              class="rounded-full border border-stone-700 px-4 py-2 text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
            >
              Device
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
        <.panel title="Snapshot Status">
          <span class={[
            "inline-flex rounded-full px-3 py-1 text-sm font-medium ring-1",
            Display.status_class(source_status(@source_snapshot))
          ]}>
            {source_status(@source_snapshot)}
          </span>
        </.panel>
        <.panel title="Interval" value={"#{@source.interval_ms} ms"} />
        <.panel title="Failures" value={to_string(@source_health.consecutive_failures)} />
        <.panel title="Backoff" value={"#{@source_health.backoff_ms} ms"} />
      </section>

      <section class="grid gap-6 xl:grid-cols-2">
        <article class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">Health State</h2>
          </div>
          <div class="grid gap-4 px-6 py-5 sm:grid-cols-2">
            <.kv label="Last OK">
              <.utc_time value={@source_health.last_ok_at} class="text-stone-50" />
            </.kv>
            <.kv label="Last Error At">
              <.utc_time value={@source_health.last_error_at} class="text-stone-50" />
            </.kv>
            <.kv label="Last Error" value={@source_health.last_error || "-"} />
            <.kv label="Observed At">
              <.utc_time
                value={@source_snapshot && @source_snapshot.observed_at}
                class="text-stone-50"
              />
            </.kv>
          </div>
        </article>

        <article class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">Probe</h2>
          </div>
          <div class="px-6 py-5">
            <.data_view
              device={@device}
              source={@source}
              data={(@source_snapshot && @source_snapshot.probe_data) || %{}}
            />
          </div>
        </article>
      </section>

      <section
        :if={preview_entries(@source_snapshot) != []}
        class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
      >
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Cached Preview</h2>
        </div>
        <div class="grid gap-4 px-6 py-5 md:grid-cols-2">
          <figure :for={entry <- preview_entries(@source_snapshot)} class="space-y-3">
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
        :if={ha_entities(@source_snapshot) != []}
        class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
      >
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Current Entities</h2>
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
              <tr :for={entity <- ha_entities(@source_snapshot)}>
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

      <section
        :if={show_current_data?(@source, @source_snapshot)}
        class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
      >
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Metrics</h2>
        </div>
        <div class="grid gap-4 px-6 py-5 md:grid-cols-2 xl:grid-cols-3">
          <div
            :for={{metric_id, value} <- metric_rows(@source_snapshot)}
            class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4"
          >
            <p class="text-xs uppercase tracking-[0.22em] text-stone-400">
              {metric_label(metric_id)}
            </p>
            <p class="mt-2 text-lg font-semibold text-stone-50">{Display.metric(metric_id, value)}</p>
          </div>
          <p :if={Enum.empty?(metric_rows(@source_snapshot))} class="px-1 py-2 text-sm text-stone-400">
            No metrics have been recorded yet.
          </p>
        </div>
      </section>

      <section
        :if={show_current_data?(@source, @source_snapshot)}
        class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80"
      >
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Current Data</h2>
        </div>
        <div class="px-6 py-5">
          <.data_view
            device={@device}
            source={@source}
            data={(@source_snapshot && @source_snapshot.data) || %{}}
          />
        </div>
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

  attr :device, :map, required: true
  attr :source, :map, required: true
  attr :data, :map, required: true

  defp data_view(%{source: %{name: :launchd}, data: %{data: %{labels: labels}}} = assigns)
       when is_list(labels) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <span
        :for={label <- @data.data.labels}
        class="rounded-full border border-stone-700 px-3 py-1 text-xs text-stone-200"
      >
        {launchd_label_name(@device, label)}
      </span>
    </div>
    """
  end

  defp data_view(%{source: %{name: :ha_web_socket}, data: %{data: data, ok: ok}} = assigns) do
    assigns =
      assign(assigns,
        ok: ok,
        auth: Display.humanize(Map.get(data, :auth, "-")),
        event_type: Display.humanize(Map.get(data, :event_type, "-")),
        entity_count: data |> Map.get(:curated_entity_ids, []) |> length(),
        websocket_path: Map.get(data, :websocket_path, "-")
      )

    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <.kv label="Probe" value={if @ok, do: "OK", else: "Failed"} />
      <.kv label="Auth" value={@auth} />
      <.kv label="Event" value={@event_type} />
      <.kv label="Tracked Entities" value={to_string(@entity_count)} />
      <.kv label="Path" value={@websocket_path} />
    </div>
    """
  end

  defp data_view(%{source: %{name: :launchd}, data: %{services: services}} = assigns)
       when is_list(services) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="min-w-full divide-y divide-stone-800 text-sm">
        <thead class="bg-stone-950/70 text-left text-xs uppercase tracking-[0.24em] text-stone-400">
          <tr>
            <th class="px-4 py-3">App</th>
            <th class="px-4 py-3">State</th>
            <th class="px-4 py-3">PID</th>
            <th class="px-4 py-3">Last Exit</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-stone-800 text-stone-200">
          <tr :for={service <- @data.services}>
            <td class="px-4 py-3 font-medium text-stone-100">
              {Map.get(service, :display_name) || service.label}
            </td>
            <td class="px-4 py-3">{if service.running, do: "running", else: "stopped"}</td>
            <td class="px-4 py-3">{Map.get(service, :pid) || "-"}</td>
            <td class="px-4 py-3">{Map.get(service, :last_exit_status) || "-"}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp data_view(
         %{source: %{name: :ha_supervisor}, data: %{addons: addons, summary: summary}} = assigns
       )
       when is_list(addons) do
    assigns = assign(assigns, addons: addons, summary: summary)

    ~H"""
    <div class="space-y-4">
      <div class="space-y-1">
        <p class="text-xs uppercase tracking-[0.22em] text-stone-400">Summary</p>
        <p class="mt-2 text-sm text-stone-100">{display_value(addon_value(@summary, :message))}</p>
      </div>
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-stone-800 text-sm">
          <thead class="bg-stone-950/70 text-left text-xs uppercase tracking-[0.24em] text-stone-400">
            <tr>
              <th class="px-4 py-3">Add-on</th>
              <th class="px-4 py-3">State</th>
              <th class="px-4 py-3">Version</th>
              <th class="px-4 py-3">Update</th>
              <th class="px-4 py-3">Required</th>
              <th class="px-4 py-3">Config Warnings</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-stone-800 text-stone-200">
            <tr :for={addon <- @addons}>
              <td class="px-4 py-3">
                <p class="font-medium text-stone-100">{addon_display_name(addon)}</p>
                <p :if={present?(addon_name_line(addon))} class="text-xs text-stone-500">
                  {addon_name_line(addon)}
                </p>
                <p class="text-xs text-stone-500">{display_value(addon_value(addon, :slug))}</p>
              </td>
              <td class="px-4 py-3">{display_value(addon_value(addon, :state))}</td>
              <td class="px-4 py-3">{version_display(addon)}</td>
              <td class="px-4 py-3">{update_display(addon_value(addon, :update_available))}</td>
              <td class="px-4 py-3">{boolean_display(addon_value(addon, :required))}</td>
              <td class="px-4 py-3">{warning_codes(addon)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp data_view(assigns) do
    ~H"""
    <pre class="overflow-x-auto whitespace-pre-wrap text-sm text-stone-200">{pretty(@data)}</pre>
    """
  end

  defp show_current_data?(%{name: :launchd}, _source_snapshot), do: true

  defp show_current_data?(_source, source_snapshot) do
    preview_entries(source_snapshot) == [] and ha_entities(source_snapshot) == []
  end

  defp current_source_snapshot(device_id, source_name) do
    device_id
    |> SnapshotStore.snapshot()
    |> then(&Map.get(&1.sources, source_name))
  end

  defp source_status(nil), do: :unknown
  defp source_status(snapshot), do: snapshot.status

  defp metric_rows(nil), do: []

  defp metric_rows(source_snapshot) do
    source_snapshot.metrics
    |> Enum.sort_by(fn {metric_id, _value} -> metric_label(metric_id) end)
  end

  defp preview_entries(nil), do: []

  defp preview_entries(source_snapshot) do
    get_in(source_snapshot.data, [:entries]) || []
  end

  defp preview_url(entry), do: "#{entry.cache_path}?etag=#{entry.etag}"

  defp ha_entities(nil), do: []

  defp ha_entities(source_snapshot) do
    get_in(source_snapshot.data, [:entities]) || []
  end

  defp metric_label(metric_id) do
    case Catalog.definition(metric_id) do
      %{id: id} ->
        humanize_metric(id)

      nil ->
        humanize_metric(metric_id)
    end
  end

  defp humanize_metric(metric_id) do
    metric_id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp entity_state(%{state: state, unit_of_measurement: nil}), do: state
  defp entity_state(%{state: state, unit_of_measurement: unit}), do: "#{state} #{unit}"

  defp launchd_label_name(device, label) do
    Enum.find_value(device.launchd_labels, label, fn
      %{label: ^label, display_name: display_name} -> display_name
      ^label -> label
      _ -> nil
    end)
  end

  defp addon_display_name(addon) do
    addon_value(addon, :label) || addon_value(addon, :name) || addon_value(addon, :slug) || "-"
  end

  defp addon_name_line(addon) do
    name = addon_value(addon, :name)
    label = addon_value(addon, :label)

    if present?(name) and name != label, do: name
  end

  defp addon_value(map, key) when is_map(map) do
    keys =
      cond do
        is_atom(key) -> [key, Atom.to_string(key)]
        is_binary(key) -> [key, existing_atom(key)]
        true -> [key]
      end

    fetch_first(map, keys)
  end

  defp addon_value(_map, _key), do: nil

  defp fetch_first(_map, []), do: nil
  defp fetch_first(map, [nil | keys]), do: fetch_first(map, keys)

  defp fetch_first(map, [key | keys]) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_first(map, keys)
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp version_display(addon) do
    version = addon_value(addon, :version)
    latest = addon_value(addon, :version_latest)

    cond do
      present?(version) and present?(latest) and version != latest -> "#{version} to #{latest}"
      present?(version) -> version
      present?(latest) -> latest
      true -> "-"
    end
  end

  defp update_display(true), do: "Available"
  defp update_display(false), do: "-"
  defp update_display(_value), do: "-"

  defp boolean_display(true), do: "Yes"
  defp boolean_display(false), do: "No"
  defp boolean_display(_value), do: "-"

  defp warning_codes(addon) do
    codes =
      addon
      |> addon_value(:config_warnings)
      |> List.wrap()
      |> Enum.map(&warning_code/1)
      |> Enum.filter(&present?/1)

    case codes do
      [] -> "-"
      codes -> Enum.join(codes, ", ")
    end
  end

  defp warning_code(warning) when is_map(warning), do: addon_value(warning, :code)
  defp warning_code(warning) when is_atom(warning), do: Atom.to_string(warning)
  defp warning_code(warning) when is_binary(warning), do: warning
  defp warning_code(_warning), do: nil

  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_atom(value), do: Atom.to_string(value)
  defp display_value(value) when is_number(value), do: to_string(value)
  defp display_value(_value), do: "-"

  defp present?(value), do: value not in [nil, ""]

  defp pretty(data), do: inspect(data, pretty: true, limit: :infinity)
end
