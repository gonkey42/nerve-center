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
       page_title: "#{device.label} #{source.name}",
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
              {@device.label} / {@source.name}
            </h1>
            <p class="mt-2 max-w-2xl text-sm text-stone-300">
              Probe data, current snapshot, and failure state for {inspect(@source.module)}.
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
            <pre class="overflow-x-auto whitespace-pre-wrap text-sm text-stone-200">{pretty(@source_snapshot && @source_snapshot.probe_data || %{})}</pre>
          </div>
        </article>
      </section>

      <section class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
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

      <section class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Current Data</h2>
        </div>
        <div class="px-6 py-5">
          <pre class="overflow-x-auto whitespace-pre-wrap text-sm text-stone-200">{pretty(@source_snapshot && @source_snapshot.data || %{})}</pre>
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

  defp pretty(data), do: inspect(data, pretty: true, limit: :infinity)
end
