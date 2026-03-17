defmodule NerveCenter.Sources.Rosie.GlancesSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Kitt.GlancesSource, as: SharedGlancesSource

  defdelegate required_env(), to: SharedGlancesSource
  defdelegate normal_interval_ms(), to: SharedGlancesSource
  defdelegate stale_after_ms(), to: SharedGlancesSource
  defdelegate probe(context), to: SharedGlancesSource
  defdelegate poll(context), to: SharedGlancesSource
  defdelegate normalize(raw, context), to: SharedGlancesSource
end
