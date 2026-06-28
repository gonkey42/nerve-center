defmodule NerveCenter.Runtime.SemanticStatus do
  @moduledoc false

  @allowed [:ok, :degraded, :error, :offline, :stale, :unknown]
  @invalid_error {:invalid_callback_payload, :invalid_semantic_status}

  def allowed, do: @allowed

  def valid?(status), do: status in @allowed

  def normalize(payload) when is_map(payload) do
    case Map.fetch(payload, :status) do
      :error -> {:ok, :ok}
      {:ok, nil} -> {:ok, :ok}
      {:ok, status} when status in @allowed -> {:ok, status}
      {:ok, _status} -> {:error, @invalid_error}
    end
  end
end
