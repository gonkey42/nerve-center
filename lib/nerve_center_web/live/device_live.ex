defmodule NerveCenterWeb.DeviceLive do
  use NerveCenterWeb, :live_view

  alias NerveCenter.Messages.AppHealthUpdated
  alias NerveCenter.Messages.DeviceSnapshotUpdated
  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Metrics.History
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
       health: AppHealth.snapshot(),
       histories: load_histories(device.id),
       energy_totals: load_energy_totals(device.id, SnapshotStore.snapshot(device.id))
     )}
  end

  @impl true
  def handle_info(%DeviceSnapshotUpdated{snapshot: snapshot}, socket) do
    {:noreply,
     assign(socket,
       snapshot: snapshot,
       histories: load_histories(socket.assigns.device.id),
       energy_totals: load_energy_totals(socket.assigns.device.id, snapshot)
     )}
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
            <.link
              :if={@device.id == :daisy}
              navigate={~p"/devices/#{Atom.to_string(@device.id)}/home-assistant"}
              class="rounded-full border border-amber-400/50 px-4 py-2 text-amber-100 transition hover:bg-amber-400/10"
            >
              HA Dashboard
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

      <section
        :if={ups_device?(@device)}
        class="grid gap-6 xl:grid-cols-[1.1fr_0.9fr]"
      >
        <article class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">UPS Overview</h2>
          </div>
          <div class="grid gap-5 px-6 py-5 md:grid-cols-2">
            <.gauge
              label="Battery"
              value={@snapshot.metrics[:ups_battery_charge_ratio]}
              display={Display.percent(@snapshot.metrics[:ups_battery_charge_ratio])}
              tone="emerald"
            />
            <.gauge
              label="Load"
              value={@snapshot.metrics[:ups_load_ratio]}
              display={Display.percent(@snapshot.metrics[:ups_load_ratio])}
              tone="amber"
            />
            <.summary_tile
              label="Runtime"
              value={Display.duration(@snapshot.metrics[:ups_battery_runtime_seconds])}
              hint={battery_status(@snapshot)}
            />
            <.summary_tile
              label="Current Load"
              value={Display.watts(@snapshot.metrics[:ups_current_load_watts])}
              hint="Watts currently under UPS load"
            />
          </div>
        </article>

        <article class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">Hardware</h2>
          </div>
          <div class="grid gap-4 px-6 py-5 sm:grid-cols-2">
            <.kv label="Model" value={ups_data(@snapshot, :model) || "-"} />
            <.kv label="Manufacturer" value={ups_data(@snapshot, :manufacturer) || "-"} />
            <.kv
              label="Input Voltage"
              value={Display.volts(@snapshot.metrics[:ups_input_voltage_volts])}
            />
            <.kv
              label="Output Voltage"
              value={Display.volts(ups_data(@snapshot, :output_voltage_volts))}
            />
            <.kv
              label="Battery Voltage"
              value={Display.volts(ups_data(@snapshot, :battery_voltage_volts))}
            />
            <.kv label="Last Test" value={ups_data(@snapshot, :test_result) || "-"} />
            <.kv label="Driver" value={driver_label(@snapshot)} />
            <.kv label="NUT Status" value={ups_data(@snapshot, :status) || "-"} />
          </div>
        </article>

        <article class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80 xl:col-span-2">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">Energy Use</h2>
          </div>
          <div class="grid gap-4 px-6 py-5 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-6">
            <.summary_tile
              label="Current Watts"
              value={Display.watts(@snapshot.metrics[:ups_current_load_watts])}
              hint="Live attached load"
            />
            <.summary_tile
              label="Last Hour"
              value={Display.kwh(@energy_totals[:hour])}
              hint="Rolling total"
            />
            <.summary_tile
              label="Last Day"
              value={Display.kwh(@energy_totals[:day])}
              hint="Rolling total"
            />
            <.summary_tile
              label="Last Week"
              value={Display.kwh(@energy_totals[:week])}
              hint="Rolling total"
            />
            <.summary_tile
              label="Last Month"
              value={Display.kwh(@energy_totals[:month])}
              hint="Rolling 30 days"
            />
            <.summary_tile
              label="Last Year"
              value={Display.kwh(@energy_totals[:year])}
              hint="Rolling 365 days"
            />
          </div>
        </article>

        <article class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80 xl:col-span-2">
          <div class="border-b border-stone-800 px-6 py-4">
            <h2 class="text-lg font-semibold text-stone-50">UPS Trends</h2>
          </div>
          <div class="grid gap-4 px-6 py-5 md:grid-cols-2 xl:grid-cols-4">
            <.trend_card
              label="Runtime"
              value={Display.duration(@snapshot.metrics[:ups_battery_runtime_seconds])}
              points={history(@histories, :ups_battery_runtime_seconds)}
            />
            <.trend_card
              label="Load"
              value={Display.percent(@snapshot.metrics[:ups_load_ratio])}
              points={history(@histories, :ups_load_ratio)}
            />
            <.trend_card
              label="Watts"
              value={Display.watts(@snapshot.metrics[:ups_current_load_watts])}
              points={history(@histories, :ups_current_load_watts)}
            />
            <.trend_card
              label="Input Voltage"
              value={Display.volts(@snapshot.metrics[:ups_input_voltage_volts])}
              points={history(@histories, :ups_input_voltage_volts)}
            />
          </div>
        </article>
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

  attr :label, :string, required: true
  attr :value, :float, default: nil
  attr :display, :string, required: true
  attr :tone, :string, default: "amber"

  defp gauge(assigns) do
    assigns =
      assigns
      |> assign(:percent, gauge_percent(assigns.value))
      |> assign(:style, gauge_style(assigns.value, assigns.tone))

    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-5">
      <div class="mx-auto grid h-36 w-36 place-items-center rounded-full" style={@style}>
        <div class="grid h-24 w-24 place-items-center rounded-full bg-stone-950 text-center">
          <div>
            <p class="text-xs uppercase tracking-[0.18em] text-stone-500">{@label}</p>
            <p class="mt-1 text-xl font-semibold text-stone-50">{@display}</p>
          </div>
        </div>
      </div>
      <div class="mt-5 h-2 overflow-hidden rounded-full bg-stone-800">
        <div class="h-full rounded-full bg-amber-300" style={"width: #{@percent}%"} />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp summary_tile(assigns) do
    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-5">
      <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
      <p class="mt-3 text-3xl font-semibold text-stone-50">{@value}</p>
      <p :if={@hint} class="mt-3 text-sm text-stone-400">{@hint}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :points, :list, default: []

  defp trend_card(assigns) do
    assigns = assign(assigns, :polyline, sparkline_points(assigns.points))

    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
      <div class="flex items-start justify-between gap-3">
        <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
        <p class="text-sm font-semibold text-stone-50">{@value}</p>
      </div>
      <svg
        viewBox="0 0 120 48"
        class="mt-4 h-16 w-full overflow-visible"
        role="img"
        aria-label={"#{@label} trend"}
      >
        <polyline
          :if={@polyline != ""}
          points={@polyline}
          fill="none"
          stroke="rgb(252 211 77)"
          stroke-width="3"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <line x1="0" y1="44" x2="120" y2="44" stroke="rgb(68 64 60)" stroke-width="1" />
      </svg>
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

  defp ups_device?(device), do: Map.get(device, :nut_device) != nil

  defp ups_device_id?(device_id) do
    device_id |> Topology.get_device!() |> ups_device?()
  rescue
    _error -> false
  end

  defp load_histories(device_id) do
    if ups_device_id?(device_id), do: load_ups_histories(device_id), else: %{}
  end

  defp load_ups_histories(device_id) do
    [
      :ups_battery_runtime_seconds,
      :ups_load_ratio,
      :ups_current_load_watts,
      :ups_input_voltage_volts
    ]
    |> Map.new(&{&1, History.recent_points(device_id, &1, 48)})
  rescue
    _error -> %{}
  end

  defp load_energy_totals(device_id, snapshot) do
    if ups_device_id?(device_id) do
      History.energy_totals(
        device_id,
        :ups_current_load_watts,
        snapshot.metrics[:ups_current_load_watts]
      )
    else
      %{}
    end
  rescue
    _error -> %{}
  end

  defp history(histories, metric_id), do: Map.get(histories, metric_id, [])

  defp ups_data(snapshot, key), do: get_in(snapshot.sources, [:nut, Access.key(:data), key])

  defp driver_label(snapshot) do
    [ups_data(snapshot, :driver_name), ups_data(snapshot, :driver_version)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "-"
      value -> value
    end
  end

  defp battery_status(snapshot) do
    cond do
      snapshot.metrics[:ups_low_battery_flag] == 1 -> "Low battery"
      snapshot.metrics[:ups_on_battery_flag] == 1 -> "On battery"
      true -> "Online"
    end
  end

  defp gauge_percent(nil), do: 0
  defp gauge_percent(value), do: value |> max(0.0) |> min(1.0) |> Kernel.*(100) |> Float.round(1)

  defp gauge_style(nil, _tone),
    do: "background: conic-gradient(rgb(68 64 60) 0deg, rgb(68 64 60) 360deg);"

  defp gauge_style(value, tone) do
    degrees = value |> max(0.0) |> min(1.0) |> Kernel.*(360) |> Float.round(1)
    color = gauge_color(tone)

    "background: conic-gradient(#{color} 0deg, #{color} #{degrees}deg, rgb(68 64 60) #{degrees}deg, rgb(68 64 60) 360deg);"
  end

  defp gauge_color("emerald"), do: "rgb(52 211 153)"
  defp gauge_color(_tone), do: "rgb(252 211 77)"

  defp sparkline_points([]), do: ""
  defp sparkline_points([_single]), do: ""

  defp sparkline_points(points) do
    values = Enum.map(points, & &1.value)
    min_value = Enum.min(values)
    max_value = Enum.max(values)
    span = max(max_value - min_value, 1.0)
    last_index = max(length(values) - 1, 1)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} ->
      x = Float.round(index / last_index * 120, 2)
      y = Float.round(42 - (value - min_value) / span * 36, 2)
      "#{x},#{y}"
    end)
  end

  defp humanize_metric(metric_id) do
    metric_id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp pretty(data), do: inspect(data, pretty: true, limit: :infinity)
end
