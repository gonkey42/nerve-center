defmodule NerveCenter.Sources.Support do
  @moduledoc false

  def request_json(url, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    method = Keyword.get(opts, :method, :get)
    json = Keyword.get(opts, :json, :unset)

    request_opts =
      [
        method: method,
        url: url,
        headers: headers ++ [{"accept", "application/json"}],
        receive_timeout: 5_000,
        connect_options: [timeout: 5_000],
        retry: false
      ]
      |> maybe_put_json(json)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} when status in [401, 403] ->
        {:error, {:auth, status, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:request, Exception.message(exception)}}
    end
  end

  defp maybe_put_json(opts, :unset), do: opts
  defp maybe_put_json(opts, json), do: Keyword.put(opts, :json, json)

  def first_present(map, keys, default \\ nil)

  def first_present(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn
      {outer_key, inner_key} ->
        map
        |> fetch_value(outer_key)
        |> case do
          inner when is_map(inner) -> fetch_value(inner, inner_key)
          _ -> nil
        end

      key ->
        fetch_value(map, key)
    end)
  end

  def ratio_from_percent(value) when is_number(value), do: value / 100
  def ratio_from_percent(value) when is_binary(value), do: to_float(value) / 100

  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value / 1

  def to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} ->
        parsed

      :error ->
        String.to_integer(value) / 1
    end
  end

  def to_integer(value) when is_integer(value), do: value
  def to_integer(value) when is_float(value), do: round(value)
  def to_integer(value) when is_binary(value), do: String.to_integer(value)

  def sum_fields(items, keys) do
    Enum.reduce(items, 0.0, fn item, acc ->
      acc + to_float(first_present(item, keys, 0))
    end)
  end

  def parse_uptime_seconds(value) when is_integer(value), do: value
  def parse_uptime_seconds(value) when is_float(value), do: round(value)

  def parse_uptime_seconds(value) when is_binary(value) do
    cond do
      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      true ->
        parse_human_uptime(value)
    end
  end

  defp fetch_value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch_value(map, key), do: Map.get(map, key)

  defp parse_human_uptime(value) do
    days = capture_int(value, ~r/(\d+)\s+day/)
    hours = capture_int(value, ~r/(\d+)\s+hour/)
    minutes = capture_int(value, ~r/(\d+)\s+minute/)
    seconds = capture_int(value, ~r/(\d+)\s+second/)

    cond do
      Regex.match?(~r/^\d+:\d+:\d+$/, value) ->
        [hours, minutes, seconds] =
          value
          |> String.split(":")
          |> Enum.map(&String.to_integer/1)

        hours * 3_600 + minutes * 60 + seconds

      true ->
        days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    end
  end

  defp capture_int(value, regex) do
    case Regex.run(regex, value, capture: :all_but_first) do
      [matched] -> String.to_integer(matched)
      _ -> 0
    end
  end
end
