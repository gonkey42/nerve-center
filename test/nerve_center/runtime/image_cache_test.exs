defmodule NerveCenter.Runtime.ImageCacheTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.ImageCache

  test "rejects entries larger than 2 MB" do
    oversized = :binary.copy(<<0>>, 2_000_001)

    assert {:error, :too_large} = ImageCache.put("oversized", oversized, "image/jpeg")
    assert :error = ImageCache.get("oversized")
  end
end
