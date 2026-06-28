defmodule NerveCenter.TestSupport.DaisySupervisorBridgeHelpers do
  @moduledoc false

  import ExUnit.Assertions

  @bridge_token "test-daisy-supervisor-bridge-token-123456"
  @forbidden_bridge_token "bridge-token-123456789012345678901234"
  @forbidden_supervisor_token "supervisor-token-should-not-leak"
  @forbidden_password "raw-nut-password-should-not-leak"
  @forbidden_body %{
    "error" => "Unauthorized",
    "token" => @forbidden_bridge_token,
    "supervisor_token" => @forbidden_supervisor_token,
    "password" => @forbidden_password,
    "Authorization" => "Bearer #{@forbidden_bridge_token}",
    "trace" => "Traceback fake bridge failure"
  }

  def bridge_token, do: @bridge_token
  def forbidden_bridge_token, do: @forbidden_bridge_token
  def forbidden_supervisor_token, do: @forbidden_supervisor_token
  def forbidden_password, do: @forbidden_password
  def forbidden_body, do: @forbidden_body

  def forbidden_fragments do
    [
      @forbidden_bridge_token,
      @forbidden_supervisor_token,
      @forbidden_password,
      "Authorization",
      "Traceback"
    ]
  end

  def assert_forbidden_absent(term) do
    encoded = inspect(term, limit: :infinity, printable_limit: :infinity)

    for forbidden <- forbidden_fragments() do
      refute encoded =~ forbidden
    end
  end

  def listen_socket do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {listener, port}
  end

  def serve_requests(listener, count, handler) do
    Task.async(fn ->
      try do
        Enum.each(1..count, fn _index ->
          {:ok, socket} = :gen_tcp.accept(listener)
          request = recv_http_request(socket)
          handler.(socket, request)
          :ok = :gen_tcp.close(socket)
        end)
      after
        :gen_tcp.close(listener)
      end
    end)
  end

  def recv_http_request(socket), do: recv_http_request(socket, "")

  def recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        request = acc <> chunk

        if String.contains?(request, "\r\n\r\n") do
          request
        else
          recv_http_request(socket, request)
        end

      {:error, reason} ->
        flunk("failed to receive HTTP request: #{inspect(reason)}")
    end
  end

  def send_response(socket, {status, body}) do
    payload = Jason.encode!(body)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(payload)}\r\n",
        "connection: close\r\n",
        "\r\n",
        payload
      ])
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(418), do: "I'm a teapot"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_status), do: "Error"
end
