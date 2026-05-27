defmodule NerveCenterWeb.DashboardLive do
  use NerveCenterWeb, :live_view

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
       snapshots: snapshots
     )}
  end

  @impl true
  def handle_info(
        %NerveCenter.Messages.DeviceSnapshotUpdated{device_id: device_id, snapshot: snapshot},
        socket
      ) do
    {:noreply, assign(socket, :snapshots, Map.put(socket.assigns.snapshots, device_id, snapshot))}
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
              HAL9000 Read-Only Dashboard
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
      </header>

      <section class="grid gap-6 lg:grid-cols-2">
        <article
          :for={device <- @devices}
          class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80 shadow-2xl shadow-black/20"
        >
          <% snapshot = Map.fetch!(@snapshots, device.id) %>
          <% launchd = get_in(snapshot.sources, [:launchd, Access.key(:data), :services]) || [] %>
          <div class="flex items-start justify-between border-b border-stone-800 px-6 py-5">
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
            <%= if device.id == :ups do %>
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
                <.utc_time value={snapshot.updated_at} class="text-xs text-stone-500" />
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
              <ul class="mt-3 space-y-2 text-sm text-stone-200">
                <li :for={service <- launchd} class="flex items-center justify-between gap-3">
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

  defp status_feed_label(snapshot) do
    case get_in(snapshot.sources, [:ha_web_socket, Access.key(:data), :connected?]) do
      false -> "disconnected"
      true -> "streaming"
      _ -> Atom.to_string(snapshot.status)
    end
  end
end
