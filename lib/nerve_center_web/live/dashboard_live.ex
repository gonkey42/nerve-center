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
            <p class="max-w-2xl text-sm text-stone-300">
              Live state for the Phase 1a and Phase 1b devices, sourced locally from HAL9000 and remotely from KITT.
            </p>
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
                  label="Input"
                  value={Display.volts(snapshot.metrics[:ups_input_voltage_volts])}
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
              <div class="grid gap-3 sm:grid-cols-2">
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
                <.metric label="Uptime" value={Display.duration(snapshot.metrics[:uptime_seconds])} />
                <.metric
                  :if={not is_nil(snapshot.metrics[:plex_active_streams_count])}
                  label="Plex"
                  value={to_string(snapshot.metrics[:plex_active_streams_count]) <> " active"}
                />
              </div>
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
                  {source_name}: {source_snapshot.status}
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
                  <span class="truncate">{service.label}</span>
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
end
