defmodule NerveCenter.Runtime.FailureReasonTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.FailureReason

  @opaque_secret "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01"

  test "redacts values for common sensitive key variants" do
    sensitive_keys = [
      "auth",
      "authHeader",
      "authorization",
      "x-auth-header",
      "credential",
      "credentials",
      "client_credentials",
      "password",
      "passwd",
      "passphrase",
      "apiToken",
      "refreshToken",
      "access-token",
      "access_token",
      "bridge-token",
      :api_token,
      "apiKey",
      "client_secret",
      "secret",
      "private-key",
      "private_key",
      "cookie",
      "session",
      "session_id",
      "sid",
      "csrf",
      "csrf-token",
      "Traceback"
    ]

    for key <- sensitive_keys do
      sanitized = FailureReason.sanitize(%{key => @opaque_secret})
      encoded = inspect(sanitized, limit: :infinity, printable_limit: :infinity)

      refute encoded =~ @opaque_secret, "expected #{inspect(key)} to redact its value"
      assert encoded =~ "redacted_sensitive_value"
    end
  end

  test "does not raise for arbitrary map keys" do
    sanitized =
      FailureReason.sanitize(%{
        {:apiToken, :tuple_key} => @opaque_secret,
        {:ordinary, :field} => "safe value"
      })

    encoded = inspect(sanitized, limit: :infinity, printable_limit: :infinity)

    refute encoded =~ @opaque_secret
    assert encoded =~ "safe value"
  end
end
