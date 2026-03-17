defmodule NerveCenter.Sources.Daisy.HARestProbe do
  @moduledoc false

  use GenServer

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Sources.Support
  alias NerveCenter.Topology

  def child_spec(opts) do
    device = Keyword.fetch!(opts, :device)
    source = Keyword.fetch!(opts, :source)

    %{
      id: {__MODULE__, device.id, source.name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def required_env, do: ["HA_TOKEN"]

  @impl true
  def init(opts) do
    state = %{
      device: Keyword.fetch!(opts, :device),
      source: Keyword.fetch!(opts, :source)
    }

    {:ok, state, {:continue, :probe}}
  end

  @impl true
  def handle_continue(:probe, state) do
    observed_at = DateTime.utc_now()

    case probe(state.device) do
      {:ok, payload} ->
        probe_data = %{ok: true, data: payload}

        PersistenceWriter.enqueue_probe(%{
          device_id: Atom.to_string(state.device.id),
          source: Atom.to_string(state.source.name),
          probe_data: probe_data,
          probed_at: observed_at
        })

        AppHealth.record_source_success(state.device.id, state.source.name, observed_at)

        publish_source_snapshot(
          state,
          %SourceSnapshot{
            device_id: state.device.id,
            source: state.source.name,
            status: :ok,
            observed_at: observed_at,
            last_ok_at: observed_at,
            last_error_at: nil,
            last_error: nil,
            probe_data: probe_data,
            consecutive_failures: 0,
            backoff_ms: 0,
            ever_ok?: true,
            metrics: %{},
            data: Map.put(payload, :connected?, true)
          },
          observed_at
        )

      {:error, reason} ->
        probe_data = %{ok: false, error: inspect(reason)}

        PersistenceWriter.enqueue_probe(%{
          device_id: Atom.to_string(state.device.id),
          source: Atom.to_string(state.source.name),
          probe_data: probe_data,
          probed_at: observed_at
        })

        AppHealth.record_source_failure(state.device.id, state.source.name, reason, 0)

        publish_source_snapshot(
          state,
          %SourceSnapshot{
            device_id: state.device.id,
            source: state.source.name,
            status: :unknown,
            observed_at: observed_at,
            last_ok_at: nil,
            last_error_at: observed_at,
            last_error: inspect(reason),
            probe_data: probe_data,
            consecutive_failures: 1,
            backoff_ms: 0,
            ever_ok?: false,
            metrics: %{},
            data: %{connected?: false}
          },
          observed_at
        )
    end

    {:noreply, state}
  end

  defp probe(device) do
    with {:ok, config} <-
           Support.request_json("#{device.home_assistant_base_url}/api/config",
             headers: [{"authorization", "Bearer #{System.fetch_env!("HA_TOKEN")}"}]
           ) do
      {:ok,
       %{
         location_name: config["location_name"],
         version: config["version"],
         state: config["state"],
         time_zone: config["time_zone"],
         temperature_unit: get_in(config, ["unit_system", "temperature"]),
         components_loaded: length(config["components"] || [])
       }}
    end
  end

  defp publish_source_snapshot(state, source_snapshot, emitted_at) do
    hub_name = {:via, Registry, {NerveCenter.Runtime.DeviceRegistry, state.device.id}}
    GenServer.cast(hub_name, {:source_update, state.source.name, source_snapshot})

    Phoenix.PubSub.broadcast(
      NerveCenter.PubSub,
      Topology.source_topic(state.device.id, state.source.name),
      %SourceSnapshotUpdated{
        device_id: state.device.id,
        source: state.source.name,
        source_snapshot: source_snapshot,
        emitted_at: emitted_at
      }
    )
  end
end
