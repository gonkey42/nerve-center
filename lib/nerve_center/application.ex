defmodule NerveCenter.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    NerveCenter.Release.migrate()
    NerveCenter.Runtime.Preflight.verify!()

    children = [
      NerveCenter.Repo,
      NerveCenter.Runtime.SnapshotStore,
      NerveCenter.Runtime.DeviceRegistry,
      NerveCenter.Runtime.ImageCache,
      NerveCenter.Runtime.AppHealth,
      NerveCenter.Runtime.PersistenceWriter,
      {Phoenix.PubSub, name: NerveCenter.PubSub},
      NerveCenter.Runtime.RetentionWorker,
      NerveCenter.Runtime.DeviceSupervisor,
      NerveCenterWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: NerveCenter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NerveCenterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
