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

  test "redacts sensitive key value pairs in binary reasons" do
    cases = [
      {"client_secret=#{@opaque_secret}", "client_secret=[REDACTED]"},
      {"apiKey: #{@opaque_secret}", "apiKey: [REDACTED]"},
      {"session_id #{@opaque_secret}", "session_id [REDACTED]"},
      {"credential=#{@opaque_secret}", "credential=[REDACTED]"},
      {~s({"client_secret":"#{@opaque_secret}"}), ~s({"client_secret":"[REDACTED]"})},
      {~s(%{"session_id" => "#{@opaque_secret}"}), ~s(%{"session_id" => "[REDACTED]"})}
    ]

    for {fragment, expected} <- cases do
      sanitized = FailureReason.sanitize("bridge failed #{fragment} while polling")

      refute sanitized =~ @opaque_secret
      assert sanitized =~ "bridge failed"
      assert sanitized =~ "while polling"
      assert sanitized =~ expected
    end
  end

  test "redacts bearer tokens in binary authorization reasons" do
    cases = [
      "Authorization: Bearer #{@opaque_secret}",
      "authorization: bearer #{@opaque_secret}",
      "bridge failed Bearer #{@opaque_secret} while polling"
    ]

    for reason <- cases do
      sanitized = FailureReason.sanitize(reason)

      refute sanitized =~ @opaque_secret
      assert sanitized =~ "[REDACTED]"
    end
  end
end
