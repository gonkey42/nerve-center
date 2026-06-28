defmodule NerveCenter.Runtime.FailureReason do
  @moduledoc false

  @redacted_response_body :redacted_response_body

  def sanitize({kind, status, body}) when kind in [:auth, :http] and is_integer(status) do
    {kind, status, sanitize_response_body(body)}
  end

  def sanitize(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&sanitize/1)
    |> List.to_tuple()
  end

  def sanitize(%module{} = reason) do
    sanitized_fields =
      reason
      |> Map.from_struct()
      |> sanitize()

    struct(module, sanitized_fields)
  rescue
    _error -> :redacted_struct
  end

  def sanitize(reason) when is_map(reason) do
    Map.new(reason, fn {key, value} ->
      {sanitize_key(key), sanitize(value)}
    end)
  end

  def sanitize(reason) when is_list(reason), do: Enum.map(reason, &sanitize/1)

  def sanitize(reason) when is_binary(reason), do: redact_string(reason)

  def sanitize(reason) when is_atom(reason) do
    redacted = reason |> Atom.to_string() |> redact_string()

    if redacted == Atom.to_string(reason) do
      reason
    else
      :redacted_atom
    end
  end

  def sanitize(reason), do: reason

  defp sanitize_response_body(body) when is_atom(body) do
    case sanitize(body) do
      ^body -> body
      _redacted -> @redacted_response_body
    end
  end

  defp sanitize_response_body(body) when is_binary(body), do: @redacted_response_body
  defp sanitize_response_body(body) when is_map(body), do: @redacted_response_body
  defp sanitize_response_body(body) when is_list(body), do: @redacted_response_body
  defp sanitize_response_body(body), do: sanitize(body)

  defp sanitize_key(key) do
    if sensitive_key?(key) do
      :redacted_key
    else
      sanitize(key)
    end
  end

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    normalized in ["authorization", "password", "token", "access_token", "bridge_token"] or
      String.ends_with?(normalized, "_token")
  end

  defp redact_string(value) do
    value
    |> redact_regex(~r/Traceback/i, "[REDACTED]")
    |> redact_regex(~r/Authorization:\s*Bearer\s+[A-Za-z0-9_-]{20,}/i, "[REDACTED]")
    |> redact_regex(~r/Bearer\s+[A-Za-z0-9_-]{20,}/, "Bearer [REDACTED]")
    |> redact_regex(~r/Authorization/i, "[REDACTED]")
    |> redact_regex(~r/[A-Za-z0-9_-]*token[A-Za-z0-9_-]*/i, "[REDACTED]")
    |> redact_regex(~r/[A-Za-z0-9_-]*password[A-Za-z0-9_-]*/i, "[REDACTED]")
  end

  defp redact_regex(value, regex, replacement), do: Regex.replace(regex, value, replacement)
end
