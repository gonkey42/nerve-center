defmodule NerveCenterWeb.DashboardLive do
  use NerveCenterWeb, :live_view

  alias NerveCenter.Metrics.History
  alias NerveCenter.Runtime.ManualControl
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Topology
  alias NerveCenterWeb.Display

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each(Topology.display_devices(), fn device ->
        Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
      end)
    end

    snapshots =
      SnapshotStore.all_snapshots()
      |> Map.new(&{&1.device_id, &1})

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       devices: Topology.display_devices(),
       snapshots: snapshots,
       histories: load_histories()
     )}
  end

  @impl true
  def handle_info(
        %NerveCenter.Messages.DeviceSnapshotUpdated{device_id: device_id, snapshot: snapshot},
        socket
      ) do
    {:noreply,
     assign(socket,
       snapshots: Map.put(socket.assigns.snapshots, device_id, snapshot),
       histories: Map.merge(socket.assigns.histories, load_histories(device_id))
     )}
  end

  @impl true
  def handle_event("refresh-device", %{"device-id" => device_id}, socket) do
    device = Topology.get_device!(device_id)

    results =
      device.sources
      |> Enum.filter(& &1.enabled)
      |> Enum.filter(&function_exported?(&1.module, :poll, 1))
      |> Enum.map(&ManualControl.refresh_source(device.id, &1.name))

    if Enum.all?(results, &match?({:ok, _snapshot}, &1)) do
      {:noreply, put_flash(socket, :info, "#{device.label} refreshed")}
    else
      {:noreply, put_flash(socket, :error, "#{device.label} refresh had errors")}
    end
  end

  def handle_event("launchd-control", %{"index" => index, "action" => action}, socket) do
    action = String.to_existing_atom(action)

    case ManualControl.control_launchd(launchd_label(index), action) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Launch agent #{Display.humanize(action)} sent")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Launch agent action failed: #{inspect(reason)}")}
    end
  end

  def handle_event("pihole-blocking", %{"enabled" => enabled} = params, socket) do
    enabled? = enabled == "true"
    timer_seconds = params |> Map.get("timer") |> parse_optional_int()

    case ManualControl.set_pihole_blocking(enabled?, timer_seconds) do
      :ok ->
        message = if enabled?, do: "Pi-hole blocking enabled", else: "Pi-hole blocking paused"
        {:noreply, put_flash(socket, :info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Pi-hole action failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-screen max-w-7xl flex-col gap-8 px-6 py-10 lg:px-10">
      <header class="flex flex-col gap-3 border-b border-stone-800 pb-6">
        <p class="text-xs uppercase tracking-[0.35em] text-amber-300">Nerve Center</p>
        <div class="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h1 class="text-4xl font-semibold tracking-tight text-stone-50">
              HAL9000 Control Dashboard
            </h1>
          </div>
          <nav class="flex gap-3 text-sm">
            <.link
              navigate={~p"/"}
              class="rounded-full border border-stone-700 bg-stone-900/70 px-4 py-2 text-stone-100"
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

      <section class="grid gap-6 lg:grid-cols-2">
        <article
          :for={device <- @devices}
          class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80 shadow-2xl shadow-black/20"
        >
          <% snapshot = Map.fetch!(@snapshots, device.id) %>
          <% launchd = get_in(snapshot.sources, [:launchd, Access.key(:data), :services]) || [] %>
          <div class="flex items-start justify-between gap-4 border-b border-stone-800 px-6 py-5">
            <div>
              <p class="text-xs uppercase tracking-[0.3em] text-stone-400">{device.hostname}</p>
              <h2 class="mt-2 text-2xl font-semibold text-stone-50">
                <.link
                  navigate={~p"/devices/#{Atom.to_string(device.id)}"}
                  class="transition hover:text-amber-300"
                >
                  {device.label}
                </.link>
              </h2>
              <p class="mt-1 text-sm text-stone-400">{device.ip}</p>
            </div>
            <span class={[
              "rounded-full px-3 py-1 text-xs font-medium ring-1",
              Display.status_class(snapshot.status)
            ]}>
              {snapshot.status}
            </span>
          </div>

          <div class="flex flex-col gap-5 px-6 py-5">
            <%= if ups_device?(device) do %>
              <div class="grid gap-4 sm:grid-cols-3">
                <.gauge
                  label="Battery"
                  value={snapshot.metrics[:ups_battery_charge_ratio]}
                  display={Display.percent(snapshot.metrics[:ups_battery_charge_ratio])}
                  tone="emerald"
                />
                <.gauge
                  label="Load"
                  value={snapshot.metrics[:ups_load_ratio]}
                  display={Display.percent(snapshot.metrics[:ups_load_ratio])}
                  tone="amber"
                />
                <.sparkline_card
                  label="Runtime"
                  value={Display.duration(snapshot.metrics[:ups_battery_runtime_seconds])}
                  points={history(@histories, device.id, :ups_battery_runtime_seconds)}
                />
              </div>
              <div class="grid gap-3 sm:grid-cols-2">
                <.metric
                  label="Battery"
                  value={Display.percent(snapshot.metrics[:ups_battery_charge_ratio])}
                />
                <.metric
                  label="Runtime"
                  value={Display.duration(snapshot.metrics[:ups_battery_runtime_seconds])}
                />
                <.metric label="Load" value={Display.percent(snapshot.metrics[:ups_load_ratio])} />
                <.metric
                  label="Current Load"
                  value={Display.watts(snapshot.metrics[:ups_current_load_watts])}
                />
                <.metric
                  label="Status"
                  value={get_in(snapshot.sources, [:nut, Access.key(:data), :status]) || "-"}
                />
                <.metric
                  label="On Battery"
                  value={Display.boolean(snapshot.metrics[:ups_on_battery_flag])}
                />
              </div>
            <% else %>
              <%= if device.id == :stig do %>
                <div class="grid gap-4 sm:grid-cols-3">
                  <.gauge
                    label="Gateway CPU"
                    value={snapshot.metrics[:unifi_gateway_cpu_ratio]}
                    display={Display.percent(snapshot.metrics[:unifi_gateway_cpu_ratio])}
                    tone="amber"
                  />
                  <.gauge
                    label="Gateway Memory"
                    value={snapshot.metrics[:unifi_gateway_memory_ratio]}
                    display={Display.percent(snapshot.metrics[:unifi_gateway_memory_ratio])}
                    tone="cyan"
                  />
                  <.sparkline_card
                    label="Clients"
                    value={Display.count(snapshot.metrics[:unifi_clients_connected_count])}
                    points={history(@histories, device.id, :unifi_clients_connected_count)}
                  />
                </div>
                <div class="grid gap-3 sm:grid-cols-2">
                  <.metric
                    label="WAN Status"
                    value={get_in(snapshot.sources, [:unifi, Access.key(:data), :wan_status]) || "-"}
                  />
                  <.metric
                    label="Connected Clients"
                    value={Display.count(snapshot.metrics[:unifi_clients_connected_count])}
                  />
                  <.metric
                    label="Gateway CPU"
                    value={Display.percent(snapshot.metrics[:unifi_gateway_cpu_ratio])}
                  />
                  <.metric
                    label="Gateway Memory"
                    value={Display.percent(snapshot.metrics[:unifi_gateway_memory_ratio])}
                  />
                </div>
              <% else %>
                <div class="grid gap-3 sm:grid-cols-2">
                  <%= if system_card?(device.id) do %>
                    <div class="sm:col-span-2 grid gap-4 sm:grid-cols-3">
                      <.gauge
                        label="CPU"
                        value={snapshot.metrics[:cpu_util_ratio]}
                        display={Display.percent(snapshot.metrics[:cpu_util_ratio])}
                        tone="amber"
                      />
                      <.gauge
                        label="Memory"
                        value={
                          ratio(
                            snapshot.metrics[:memory_used_bytes],
                            snapshot.metrics[:memory_total_bytes]
                          )
                        }
                        display={
                          Display.percent(
                            ratio(
                              snapshot.metrics[:memory_used_bytes],
                              snapshot.metrics[:memory_total_bytes]
                            )
                          )
                        }
                        tone="cyan"
                      />
                      <.sparkline_card
                        label="Network RX"
                        value={Display.throughput(snapshot.metrics[:network_rx_bytes_per_sec])}
                        points={history(@histories, device.id, :network_rx_bytes_per_sec)}
                      />
                    </div>
                    <.metric label="CPU" value={Display.percent(snapshot.metrics[:cpu_util_ratio])} />
                    <.metric
                      label="Memory"
                      value={
                        memory_display(
                          snapshot.metrics[:memory_used_bytes],
                          snapshot.metrics[:memory_total_bytes]
                        )
                      }
                    />
                    <.metric
                      label="Disk"
                      value={
                        memory_display(
                          snapshot.metrics[:disk_used_bytes],
                          snapshot.metrics[:disk_total_bytes]
                        )
                      }
                    />
                    <.metric
                      label="Network"
                      value={
                        "#{Display.throughput(snapshot.metrics[:network_rx_bytes_per_sec])} / #{Display.throughput(snapshot.metrics[:network_tx_bytes_per_sec])}"
                      }
                    />
                    <.metric
                      label="Uptime"
                      value={Display.duration(snapshot.metrics[:uptime_seconds])}
                    />
                    <.metric
                      :if={not is_nil(snapshot.metrics[:plex_active_streams_count])}
                      label="Plex"
                      value={to_string(snapshot.metrics[:plex_active_streams_count]) <> " active"}
                    />
                  <% else %>
                    <.metric label="Status Feed" value={status_feed_label(snapshot)} />
                    <.metric label="Entities" value={to_string(length(ha_entities(snapshot)))} />
                  <% end %>
                </div>
              <% end %>
            <% end %>

            <div
              :if={not is_nil(snapshot.metrics[:pihole_queries_today_count])}
              class="grid gap-3 sm:grid-cols-2"
            >
              <div class="sm:col-span-2 grid gap-3 sm:grid-cols-3">
                <.sparkline_card
                  label="Queries"
                  value={Display.count(snapshot.metrics[:pihole_queries_today_count])}
                  points={history(@histories, device.id, :pihole_queries_today_count)}
                />
                <.gauge
                  label="Blocked"
                  value={snapshot.metrics[:pihole_blocked_ratio]}
                  display={Display.percent(snapshot.metrics[:pihole_blocked_ratio])}
                  tone="emerald"
                />
                <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
                  <p class="text-xs uppercase tracking-[0.22em] text-stone-400">Blocking</p>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <button
                      type="button"
                      phx-click="pihole-blocking"
                      phx-value-enabled="false"
                      phx-value-timer="300"
                      data-confirm="Pause Pi-hole blocking for 5 minutes?"
                      class="rounded-full border border-amber-500/40 px-3 py-1 text-xs text-amber-100 transition hover:bg-amber-500/10"
                    >
                      Pause 5m
                    </button>
                    <button
                      type="button"
                      phx-click="pihole-blocking"
                      phx-value-enabled="false"
                      phx-value-timer="1800"
                      data-confirm="Pause Pi-hole blocking for 30 minutes?"
                      class="rounded-full border border-amber-500/40 px-3 py-1 text-xs text-amber-100 transition hover:bg-amber-500/10"
                    >
                      Pause 30m
                    </button>
                    <button
                      type="button"
                      phx-click="pihole-blocking"
                      phx-value-enabled="true"
                      data-confirm="Enable Pi-hole blocking now?"
                      class="rounded-full border border-emerald-500/40 px-3 py-1 text-xs text-emerald-100 transition hover:bg-emerald-500/10"
                    >
                      Enable
                    </button>
                  </div>
                </div>
              </div>
              <.metric
                label="Pi-hole Blocking"
                value={Display.boolean(snapshot.metrics[:pihole_blocking_enabled_flag])}
              />
              <.metric
                label="Queries Today"
                value={to_string(snapshot.metrics[:pihole_queries_today_count] || 0)}
              />
              <.metric
                label="Blocked Today"
                value={to_string(snapshot.metrics[:pihole_blocked_queries_today_count] || 0)}
              />
              <.metric
                label="Blocked Ratio"
                value={Display.percent(snapshot.metrics[:pihole_blocked_ratio])}
              />
            </div>

            <div
              :if={device.id == :rosie and not is_nil(snapshot.metrics[:frigate_process_fps])}
              class="grid gap-3 sm:grid-cols-2"
            >
              <.metric
                label="Frigate Detect"
                value={Display.count(snapshot.metrics[:frigate_detection_fps]) <> " fps"}
              />
              <.metric
                label="Frigate Process"
                value={Display.count(snapshot.metrics[:frigate_process_fps]) <> " fps"}
              />
            </div>

            <div
              :if={device.id == :rosie and not is_nil(snapshot.metrics[:immich_assets_count])}
              class="grid gap-3 sm:grid-cols-2"
            >
              <.metric
                label="Immich Assets"
                value={Display.count(snapshot.metrics[:immich_assets_count])}
              />
              <.metric
                label="Immich Photos"
                value={Display.count(snapshot.metrics[:immich_images_count])}
              />
              <.metric
                label="Immich Videos"
                value={Display.count(snapshot.metrics[:immich_videos_count])}
              />
              <.metric
                label="Immich Storage"
                value={Display.bytes(snapshot.metrics[:immich_storage_used_bytes])}
              />
            </div>

            <div
              :if={device.id == :rosie and preview_entries(snapshot) != []}
              class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4"
            >
              <div class="flex items-center justify-between">
                <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-stone-400">
                  Frigate Preview
                </h3>
                <.utc_time
                  value={preview_entries(snapshot) |> List.first() |> Map.get(:fetched_at)}
                  class="text-xs text-stone-500"
                />
              </div>
              <div class="mt-3 grid gap-4">
                <figure :for={entry <- preview_entries(snapshot)} class="space-y-2">
                  <img
                    src={preview_url(entry)}
                    alt={"Frigate preview for #{entry.camera_name}"}
                    class="h-48 w-full rounded-2xl border border-stone-800 object-cover"
                  />
                  <figcaption class="flex items-center justify-between text-xs text-stone-400">
                    <span>{entry.camera_name}</span>
                    <span>{Display.bytes(entry.size_bytes)}</span>
                  </figcaption>
                </figure>
              </div>
            </div>

            <div
              :if={device.id == :daisy}
              class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4"
            >
              <div class="flex items-center justify-between">
                <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-stone-400">
                  Home Assistant
                </h3>
                <span class="text-xs text-stone-500">{status_feed_label(snapshot)}</span>
              </div>
              <div class="mt-3 space-y-2">
                <div
                  :for={entity <- ha_entities(snapshot)}
                  class="flex items-center justify-between gap-4 rounded-2xl border border-stone-800 bg-stone-900/70 px-3 py-2"
                >
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium text-stone-100">{entity.friendly_name}</p>
                  </div>
                  <div class="text-right">
                    <p class="text-sm text-stone-100">{entity_state(entity)}</p>
                    <.utc_time value={entity.last_updated} class="text-xs text-stone-500" />
                  </div>
                </div>
                <p :if={ha_entities(snapshot) == []} class="text-sm text-stone-400">
                  Awaiting current Home Assistant state.
                </p>
              </div>
            </div>

            <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
              <div class="flex items-center justify-between">
                <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-stone-400">
                  Sources
                </h3>
                <div class="flex items-center gap-3">
                  <.utc_time value={snapshot.updated_at} class="text-xs text-stone-500" />
                  <button
                    type="button"
                    phx-click="refresh-device"
                    phx-value-device-id={device.id}
                    class="rounded-full border border-stone-700 px-3 py-1 text-xs text-stone-300 transition hover:border-stone-500 hover:text-stone-100"
                  >
                    Refresh
                  </button>
                </div>
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                <.link
                  :for={
                    {source_name, source_snapshot} <-
                      Enum.sort_by(snapshot.sources, fn {name, _snapshot} -> name end)
                  }
                  navigate={~p"/sources/#{Atom.to_string(device.id)}/#{Atom.to_string(source_name)}"}
                  class={[
                    "rounded-full px-3 py-1 text-xs ring-1 transition hover:border-stone-500",
                    Display.status_class(source_snapshot.status)
                  ]}
                >
                  {Display.source_name(source_name)}: {source_snapshot.status}
                </.link>
                <span :if={map_size(snapshot.sources) == 0} class="text-sm text-stone-500">
                  Awaiting first successful poll.
                </span>
              </div>
            </div>

            <div :if={launchd != []} class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
              <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-stone-400">
                Launchd
              </h3>
              <ul class="mt-3 space-y-3 text-sm text-stone-200">
                <li
                  :for={{service, index} <- launchd_with_indexes(launchd)}
                  class="flex flex-col gap-2 rounded-2xl border border-stone-800 bg-stone-900/60 p-3"
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="truncate">{launchd_display_name(service)}</span>
                    <span class={[
                      "rounded-full px-2 py-1 text-xs ring-1",
                      if(service.running,
                        do: Display.status_class(:ok),
                        else: Display.status_class(:offline)
                      )
                    ]}>
                      {if service.running, do: "running", else: "stopped"}
                    </span>
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <button
                      :for={action <- launchd_actions(service)}
                      type="button"
                      phx-click="launchd-control"
                      phx-value-index={index}
                      phx-value-action={action}
                      data-confirm={"#{Display.humanize(action)} #{launchd_display_name(service)}?"}
                      class="rounded-full border border-stone-700 px-3 py-1 text-xs text-stone-300 transition hover:border-amber-400/60 hover:text-amber-100"
                    >
                      {Display.humanize(action)}
                    </button>
                  </div>
                </li>
              </ul>
            </div>

            <p :if={snapshot.status == :unknown} class="text-sm text-stone-400">
              Awaiting the first successful source update. This is the seeded `unknown` state from `SnapshotStore`.
            </p>
          </div>
        </article>
      </section>
    </main>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
      <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
      <p class="mt-2 text-lg font-semibold text-stone-50">{@value}</p>
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
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
      <div class="mx-auto grid h-28 w-28 place-items-center rounded-full" style={@style}>
        <div class="grid h-20 w-20 place-items-center rounded-full bg-stone-950 text-center">
          <div>
            <p class="text-xs uppercase tracking-[0.18em] text-stone-500">{@label}</p>
            <p class="mt-1 text-lg font-semibold text-stone-50">{@display}</p>
          </div>
        </div>
      </div>
      <div class="mt-3 h-1.5 overflow-hidden rounded-full bg-stone-800">
        <div class="h-full rounded-full bg-amber-300" style={"width: #{@percent}%"} />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :points, :list, default: []

  defp sparkline_card(assigns) do
    assigns = assign(assigns, :polyline, sparkline_points(assigns.points))

    ~H"""
    <div class="rounded-2xl border border-stone-800 bg-stone-950/70 p-4">
      <div class="flex items-start justify-between gap-3">
        <p class="text-xs uppercase tracking-[0.22em] text-stone-400">{@label}</p>
        <p class="text-sm font-semibold text-stone-50">{@value}</p>
      </div>
      <svg
        viewBox="0 0 120 42"
        class="mt-4 h-12 w-full overflow-visible"
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
        <line x1="0" y1="40" x2="120" y2="40" stroke="rgb(68 64 60)" stroke-width="1" />
      </svg>
    </div>
    """
  end

  defp memory_display(nil, _total), do: "-"
  defp memory_display(_used, nil), do: "-"
  defp memory_display(used, total), do: "#{Display.bytes(used)} / #{Display.bytes(total)}"

  defp preview_entries(snapshot) do
    get_in(snapshot.sources, [:frigate_preview, Access.key(:data), :entries]) || []
  end

  defp preview_url(entry), do: "#{entry.cache_path}?etag=#{entry.etag}"

  defp ha_entities(snapshot) do
    get_in(snapshot.sources, [:ha_web_socket, Access.key(:data), :entities]) || []
  end

  defp entity_state(%{state: state, unit_of_measurement: nil}), do: state
  defp entity_state(%{state: state, unit_of_measurement: unit}), do: "#{state} #{unit}"

  defp launchd_display_name(%{display_name: display_name}), do: display_name
  defp launchd_display_name(%{label: label}), do: label

  defp system_card?(device_id), do: device_id in [:hal9000, :kitt, :rosie, :zoidberg]

  defp ups_device?(device), do: Map.get(device, :nut_device) != nil

  defp load_histories do
    Topology.display_devices()
    |> Enum.map(&{&1.id, load_histories(&1.id)})
    |> Enum.reduce(%{}, fn {_device_id, histories}, acc -> Map.merge(acc, histories) end)
  end

  defp load_histories(device_id) do
    metrics =
      [
        :cpu_util_ratio,
        :network_rx_bytes_per_sec,
        :pihole_queries_today_count,
        :ups_battery_runtime_seconds,
        :unifi_clients_connected_count
      ]

    Map.new(metrics, fn metric_id ->
      {{device_id, metric_id}, History.recent_points(device_id, metric_id)}
    end)
  rescue
    _error -> %{}
  end

  defp history(histories, device_id, metric_id),
    do: Map.get(histories, {device_id, metric_id}, [])

  defp ratio(used, total) when is_number(used) and is_number(total) and total > 0,
    do: used / total

  defp ratio(_used, _total), do: nil

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
  defp gauge_color("cyan"), do: "rgb(34 211 238)"
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
      y = Float.round(38 - (value - min_value) / span * 34, 2)
      "#{x},#{y}"
    end)
  end

  defp launchd_actions(%{running: true}), do: [:restart, :stop]
  defp launchd_actions(_service), do: [:start]

  defp launchd_with_indexes(services), do: Enum.with_index(services)

  defp launchd_label(index) do
    index = String.to_integer(index)
    device = Topology.get_device!(:hal9000)

    device.launchd_labels
    |> Enum.at(index)
    |> case do
      %{label: label} -> label
      label when is_binary(label) -> label
    end
  end

  defp parse_optional_int(nil), do: nil

  defp parse_optional_int(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp status_feed_label(snapshot) do
    case get_in(snapshot.sources, [:ha_web_socket, Access.key(:data), :connected?]) do
      false -> "disconnected"
      true -> "streaming"
      _ -> Atom.to_string(snapshot.status)
    end
  end
end
