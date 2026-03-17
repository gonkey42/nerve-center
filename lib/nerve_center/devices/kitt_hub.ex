defmodule NerveCenter.Devices.KittHub do
  @moduledoc false

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {NerveCenter.Runtime.DeviceHub, :start_link, [opts]},
      restart: :permanent
    }
  end
end
