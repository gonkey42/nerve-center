defmodule NerveCenter.Runtime.ImageCache do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @max_entry_size 2_000_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get(camera_name) do
    case :ets.lookup(@table, camera_name) do
      [{^camera_name, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  def put(camera_name, jpeg_binary, content_type)
      when byte_size(jpeg_binary) <= @max_entry_size do
    entry = %{
      camera_name: camera_name,
      jpeg_binary: jpeg_binary,
      content_type: content_type,
      etag: :erlang.phash2(jpeg_binary),
      fetched_at: DateTime.utc_now()
    }

    :ets.insert(@table, {camera_name, entry})
    :ok
  end

  def put(_camera_name, _jpeg_binary, _content_type), do: {:error, :too_large}

  @impl true
  def init(_state) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
