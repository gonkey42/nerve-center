defmodule NerveCenter.Runtime.PollingSource do
  @moduledoc """
  Polling sources return normalized payloads with optional semantic status.

  When `normalize/2` returns `{:ok, payload}`, `payload.status` may be
  `:ok`, `:degraded`, `:error`, `:offline`, `:stale`, or `:unknown`.
  If absent or nil, runners publish `:ok` to preserve current metric-source behavior.
  Semantic statuses describe the monitored subject, not source transport health.
  Any other status value is an invalid callback payload and must not be published.
  """

  @callback required_env() :: [String.t()]
  @callback probe(map()) :: {:ok, map()} | {:error, term()}
  @callback poll(map()) :: {:ok, term()} | {:error, term()}
  @callback normalize(term(), map()) :: {:ok, map()} | {:error, term()}
  @callback normal_interval_ms() :: pos_integer()
  @callback stale_after_ms() :: pos_integer()

  defmacro __using__(_opts) do
    quote do
      @behaviour NerveCenter.Runtime.PollingSource

      def child_spec(opts) do
        NerveCenter.Runtime.PollingSourceRunner.child_spec(Keyword.put(opts, :module, __MODULE__))
      end
    end
  end
end
