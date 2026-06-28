defmodule NerveCenter.Runtime.FailureReasonTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.FailureReason

  @opaque_secret "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01"

  test "redacts values for common sensitive key variants" do
    sanitized =
      FailureReason.sanitize(%{
        "apiToken" => @opaque_secret,
        "refreshToken" => @opaque_secret,
        "access-token" => @opaque_secret,
        "access_token" => @opaque_secret,
        "bridge-token" => @opaque_secret,
        :api_token => @opaque_secret,
        "Authorization" => @opaque_secret,
        "password" => @opaque_secret,
        "Traceback" => @opaque_secret
      })

    encoded = inspect(sanitized, limit: :infinity, printable_limit: :infinity)

    refute encoded =~ @opaque_secret
    assert encoded =~ "redacted_sensitive_value"
  end

  test "does not raise for arbitrary map keys" do
    sanitized =
      FailureReason.sanitize(%{
        {:apiToken, :tuple_key} => @opaque_secret,
        {:ordinary, :tuple_key} => "safe value"
      })

    encoded = inspect(sanitized, limit: :infinity, printable_limit: :infinity)

    refute encoded =~ @opaque_secret
    assert encoded =~ "safe value"
  end
end
