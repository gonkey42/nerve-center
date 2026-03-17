defmodule NerveCenter.Sources.Zoidberg.GlancesSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Kitt.GlancesSource, as: SharedGlancesSource

  @impl true
  def required_env, do: SharedGlancesSource.required_env()

  @impl true
  def probe(context), do: SharedGlancesSource.probe(context)

  @impl true
  def poll(context), do: SharedGlancesSource.poll(context)

  @impl true
  def normalize(raw, context), do: SharedGlancesSource.normalize(raw, context)

  @impl true
  def normal_interval_ms, do: 60_000

  @impl true
  def stale_after_ms, do: 180_000
end
