defmodule NerveCenterWeb.SourcesLive do
  use NerveCenterWeb, :live_view

  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Topology
  alias NerveCenter.Topology

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    end

    {:ok, assign(socket, page_title: "Sources", health: AppHealth.snapshot())}
  end

  @impl true
  def handle_info(%NerveCenter.Messages.AppHealthUpdated{health: health}, socket) do
    {:noreply, assign(socket, :health, health)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-screen max-w-7xl flex-col gap-8 px-6 py-10 lg:px-10">
      <header class="flex flex-col gap-3 border-b border-stone-800 pb-6">
        <p class="text-xs uppercase tracking-[0.35em] text-amber-300">Sources</p>
        <div class="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h1 class="text-4xl font-semibold tracking-tight text-stone-50">App Health</h1>
            <p class="max-w-2xl text-sm text-stone-300">
              Migration, persistence, and per-source failure state for the enabled sources across the deployed devices.
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
              class="rounded-full border border-stone-700 bg-stone-900/70 px-4 py-2 text-stone-100"
            >
              Sources
            </.link>
          </nav>
        </div>
      </header>

      <section class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <.panel title="Release" value={@health.release_version} />
        <.panel title="Boot Time">
          <.utc_time value={@health.boot_time} class="text-lg font-semibold text-stone-50" />
        </.panel>
        <.panel title="Migration">
          <div class="flex items-center gap-3">
            <span class="rounded-full bg-emerald-500/20 px-3 py-1 text-xs text-emerald-200 ring-1 ring-emerald-400/30">
              {@health.migration.status}
            </span>
            <.utc_time value={@health.migration.at} class="text-sm text-stone-300" />
          </div>
        </.panel>
        <.panel title="Persistence Queue" value={to_string(@health.persistence.queue_depth)} />
      </section>

      <section class="overflow-hidden rounded-3xl border border-stone-800 bg-stone-900/80">
        <div class="border-b border-stone-800 px-6 py-4">
          <h2 class="text-lg font-semibold text-stone-50">Enabled Sources</h2>
        </div>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-stone-800 text-sm">
            <thead class="bg-stone-950/70 text-left text-xs uppercase tracking-[0.24em] text-stone-400">
              <tr>
                <th class="px-6 py-3">Device</th>
                <th class="px-6 py-3">Source</th>
                <th class="px-6 py-3">Last OK</th>
                <th class="px-6 py-3">Failures</th>
                <th class="px-6 py-3">Backoff</th>
                <th class="px-6 py-3">Last Error</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-800 text-stone-200">
              <tr :for={
                {_key, source} <-
                  Enum.sort_by(@health.sources, fn {{device_id, source_name}, _state} ->
                    {device_id, source_name}
                  end)
              }>
                <td class="px-6 py-4 font-medium">{source.device_id}</td>
                <td class="px-6 py-4">
                  <.link
                    navigate={
                      ~p"/sources/#{Atom.to_string(source.device_id)}/#{Atom.to_string(source.source)}"
                    }
                    class="text-stone-100 transition hover:text-amber-300"
                  >
                    {source.source}
                  </.link>
                </td>
                <td class="px-6 py-4">
                  <.utc_time value={source.last_ok_at} class="text-stone-300" />
                </td>
                <td class="px-6 py-4">{source.consecutive_failures}</td>
                <td class="px-6 py-4">{source.backoff_ms} ms</td>
                <td class="px-6 py-4 text-stone-400">{source.last_error || "-"}</td>
              </tr>
            </tbody>
          </table>
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
end
