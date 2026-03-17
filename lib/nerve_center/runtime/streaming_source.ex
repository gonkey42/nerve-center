defmodule NerveCenter.Runtime.StreamingSource do
  @moduledoc false

  @type connect_spec :: %{
          required(:scheme) => :ws | :wss,
          required(:transport_scheme) => :http | :https,
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          required(:path) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:private) => map()
        }

  @type frame_result :: %{
          optional(:outbound) => [map()],
          optional(:private) => map(),
          optional(:snapshot) => map()
        }

  @callback required_env() :: [String.t()]
  @callback probe(map()) :: {:ok, map()} | {:error, term()}
  @callback connect(map()) :: {:ok, connect_spec()} | {:error, term()}
  @callback handle_frame(map(), map()) :: {:ok, frame_result()} | {:error, term()}
  @callback handle_disconnect(term(), map()) :: {:ok, map()} | {:error, term()}
  @callback stale_after_ms() :: pos_integer()

  defmacro __using__(_opts) do
    quote do
      @behaviour NerveCenter.Runtime.StreamingSource

      def child_spec(opts) do
        NerveCenter.Runtime.StreamingSourceRunner.child_spec(
          Keyword.put(opts, :module, __MODULE__)
        )
      end
    end
  end
end
