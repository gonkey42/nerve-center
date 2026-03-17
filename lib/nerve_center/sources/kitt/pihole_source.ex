defmodule NerveCenter.Sources.Kitt.PiHoleSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @impl true
  def required_env, do: ["PIHOLE_APP_PASSWORD"]

  @impl true
  def normal_interval_ms, do: 30_000

  @impl true
  def stale_after_ms, do: 90_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       api_base_url: api_base_url(context),
       auth: "app_password_session"
     }}
  end

  @impl true
  def poll(context) do
    case fetch_with_session(context, existing_session(context)) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, {:auth, _, _}} ->
        with {:ok, session} <- authenticate(context),
             {:ok, raw} <- fetch_with_session(context, session) do
          {:ok, raw}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def normalize(raw, _context) do
    queries = raw.summary["queries"] || %{}
    clients = raw.summary["clients"] || %{}
    gravity = raw.summary["gravity"] || %{}
    total_queries = queries |> Support.first_present([:total], 0) |> Support.to_integer()

    blocked_queries =
      queries
      |> Support.first_present([:blocked], 0)
      |> Support.to_integer()

    blocked_ratio =
      queries
      |> Support.first_present([:percent_blocked], 0)
      |> Support.ratio_from_percent()

    blocking_status = Support.first_present(raw.blocking, [:blocking], "unknown")
    blocking_enabled = if blocking_status == "enabled", do: 1, else: 0

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       private: %{session: raw.session},
       metrics: [
         %{metric: :pihole_queries_today_count, value: total_queries},
         %{metric: :pihole_blocked_queries_today_count, value: blocked_queries},
         %{metric: :pihole_blocked_ratio, value: blocked_ratio},
         %{metric: :pihole_blocking_enabled_flag, value: blocking_enabled}
       ],
       data: %{
         blocking_status: blocking_status,
         blocking_timer: raw.blocking["timer"],
         queries_today: total_queries,
         blocked_queries_today: blocked_queries,
         blocked_ratio: blocked_ratio,
         active_clients: Support.first_present(clients, [:active], 0),
         total_clients: Support.first_present(clients, [:total], 0),
         gravity_domains_being_blocked:
           Support.first_present(gravity, [:domains_being_blocked], 0),
         gravity_last_update: Support.first_present(gravity, [:last_update], nil)
       }
     }}
  end

  defp existing_session(context) do
    case context.private do
      %{session: %{sid: sid, validity: validity}} when is_binary(sid) ->
        %{sid: sid, validity: validity}

      _ ->
        nil
    end
  end

  defp fetch_with_session(context, nil) do
    with {:ok, session} <- authenticate(context) do
      fetch_with_session(context, session)
    end
  end

  defp fetch_with_session(context, session) do
    headers = [{"x-ftl-sid", session.sid}]

    with {:ok, summary} <-
           Support.request_json("#{api_base_url(context)}/stats/summary", headers: headers),
         {:ok, blocking} <-
           Support.request_json("#{api_base_url(context)}/dns/blocking", headers: headers) do
      {:ok, %{summary: summary, blocking: blocking, session: session}}
    end
  end

  defp authenticate(context) do
    payload = %{password: System.fetch_env!("PIHOLE_APP_PASSWORD")}

    with {:ok, response} <-
           Support.request_json("#{api_base_url(context)}/auth",
             method: :post,
             json: payload
           ),
         %{"session" => session} <- response,
         true <- session["valid"],
         sid when is_binary(sid) <- session["sid"] do
      {:ok,
       %{
         sid: sid,
         validity: session["validity"],
         csrf: session["csrf"]
       }}
    else
      false ->
        {:error, {:auth, 401, %{message: "invalid Pi-hole session"}}}

      nil ->
        {:error, {:auth, 401, %{message: "missing Pi-hole SID"}}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:auth, 401, other}}
    end
  end

  defp api_base_url(context), do: "#{context.device.pihole_base_url}/api"
end
