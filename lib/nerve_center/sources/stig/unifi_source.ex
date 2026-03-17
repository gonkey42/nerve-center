defmodule NerveCenter.Sources.Stig.UniFiSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @impl true
  def required_env, do: ["UNIFI_API_KEY"]

  @impl true
  def normal_interval_ms, do: 60_000

  @impl true
  def stale_after_ms, do: 180_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       api_base_url: api_base_url(context),
       auth: "x-api-key",
       tls_verification: "scoped_verify_none"
     }}
  end

  @impl true
  def poll(context) do
    request_opts = [
      headers: [{"X-API-Key", System.fetch_env!("UNIFI_API_KEY")}],
      connect_options: [transport_opts: [verify: :verify_none]]
    ]

    with {:ok, health} <-
           Support.request_json("#{api_base_url(context)}/stat/health", request_opts),
         {:ok, devices} <-
           Support.request_json("#{api_base_url(context)}/stat/device", request_opts),
         {:ok, clients} <- Support.request_json("#{api_base_url(context)}/stat/sta", request_opts) do
      {:ok,
       %{
         health: response_data(health),
         devices: response_data(devices),
         clients: response_data(clients)
       }}
    end
  end

  @impl true
  def normalize(raw, _context) do
    wan = health_subsystem(raw.health, "wan")
    gateway = gateway(raw.devices)
    clients = Enum.map(List.wrap(raw.clients), &client_entry/1)
    connected_clients_count = length(clients)

    gateway_cpu_ratio = percent_ratio(gateway_stats_value(gateway, wan, "cpu"))
    gateway_memory_ratio = percent_ratio(gateway_stats_value(gateway, wan, "mem"))
    wan_up_flag = flag(wan_up?(gateway, wan))

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       metrics: [
         %{metric: :unifi_clients_connected_count, value: connected_clients_count},
         %{metric: :unifi_wan_up_flag, value: wan_up_flag},
         %{metric: :unifi_gateway_cpu_ratio, value: gateway_cpu_ratio},
         %{metric: :unifi_gateway_memory_ratio, value: gateway_memory_ratio}
       ],
       data: %{
         gateway_name: gateway_name(gateway, wan),
         gateway_model: Support.first_present(gateway, [:model], nil),
         gateway_version:
           Support.first_present(
             gateway,
             [:version],
             Support.first_present(wan, [:gw_version], nil)
           ),
         gateway_uptime_seconds:
           gateway
           |> Support.first_present([:uptime], gateway_stats_value(gateway, wan, "uptime"))
           |> Support.to_integer(),
         wan_status: Support.first_present(wan, [:status], "unknown"),
         wan_up: wan_up_flag == 1,
         wan_ip: wan_ip(gateway, wan),
         isp_name: Support.first_present(wan, [:isp_name], nil),
         connected_clients_count: connected_clients_count,
         gateway_cpu_ratio: gateway_cpu_ratio,
         gateway_memory_ratio: gateway_memory_ratio,
         gateway_uplink: %{
           name: Support.first_present(gateway, [{:uplink, :name}], nil),
           up: Support.first_present(gateway, [{:uplink, :up}], false),
           media: Support.first_present(gateway, [{:uplink, :media}], nil),
           ip: Support.first_present(gateway, [{:uplink, :ip}], nil),
           latency_ms: Support.first_present(gateway, [{:uplink, :latency}], nil)
         },
         clients: clients
       }
     }}
  end

  defp api_base_url(context) do
    "#{context.device.unifi_base_url}/proxy/network/api/s/#{context.device.unifi_site_slug}"
  end

  defp response_data(%{"data" => data}), do: data
  defp response_data(%{data: data}), do: data
  defp response_data(data) when is_list(data), do: data
  defp response_data(data), do: data

  defp health_subsystem(items, subsystem) do
    Enum.find(List.wrap(items), fn item ->
      Support.first_present(item, [:subsystem], nil) == subsystem
    end) || %{}
  end

  defp gateway(items) do
    Enum.find(List.wrap(items), fn item ->
      Support.first_present(item, [:type], nil) in ["udm", "ugw", "uxg"]
    end) || List.first(List.wrap(items)) || %{}
  end

  defp gateway_name(gateway, wan) do
    Support.first_present(gateway, [:name], Support.first_present(wan, [:gw_name], nil))
  end

  defp gateway_stats_value(gateway, wan, key) do
    gateway
    |> Support.first_present(
      [{"system-stats", key}],
      Support.first_present(wan, [{"gw_system-stats", key}], 0)
    )
  end

  defp percent_ratio(nil), do: 0.0
  defp percent_ratio(value), do: value |> Support.to_float() |> Support.ratio_from_percent()

  defp wan_up?(gateway, wan) do
    case Support.first_present(gateway, [{:uplink, :up}], nil) do
      true -> true
      false -> false
      nil -> Support.first_present(wan, [:status], "unknown") == "ok"
    end
  end

  defp wan_ip(gateway, wan) do
    Support.first_present(wan, [:wan_ip], Support.first_present(gateway, [{:uplink, :ip}], nil))
  end

  defp client_entry(client) do
    %{
      name: Support.first_present(client, [:name], nil),
      hostname: Support.first_present(client, [:hostname], nil),
      ip: Support.first_present(client, [:ip], nil),
      mac: Support.first_present(client, [:mac], nil),
      wired?: Support.first_present(client, [:is_wired], false),
      last_seen:
        client
        |> Support.first_present([:last_seen], nil)
        |> unix_to_datetime()
    }
  end

  defp unix_to_datetime(nil), do: nil

  defp unix_to_datetime(value) do
    value
    |> Support.to_integer()
    |> DateTime.from_unix!()
  end

  defp flag(true), do: 1
  defp flag(_), do: 0
end
