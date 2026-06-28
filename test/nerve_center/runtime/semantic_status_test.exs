defmodule NerveCenter.Runtime.SemanticStatusTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.SemanticStatus

  test "normalizes missing and nil status to ok" do
    assert SemanticStatus.normalize(%{}) == {:ok, :ok}
    assert SemanticStatus.normalize(%{status: nil}) == {:ok, :ok}
  end

  test "preserves every allowed semantic status" do
    assert SemanticStatus.allowed() == [:ok, :degraded, :error, :offline, :stale, :unknown]

    for status <- SemanticStatus.allowed() do
      assert SemanticStatus.normalize(%{status: status}) == {:ok, status}
      assert SemanticStatus.valid?(status)
    end
  end

  test "rejects invalid semantic statuses" do
    assert SemanticStatus.normalize(%{status: false}) ==
             {:error, {:invalid_callback_payload, :invalid_semantic_status}}

    assert SemanticStatus.normalize(%{status: :maintenance}) ==
             {:error, {:invalid_callback_payload, :invalid_semantic_status}}
  end
end
