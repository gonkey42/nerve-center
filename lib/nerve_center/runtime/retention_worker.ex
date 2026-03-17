defmodule NerveCenter.Runtime.RetentionWorker do
  @moduledoc false

  use GenServer

  alias NerveCenter.Runtime.PersistenceWriter

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_state) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run_retention, state) do
    PersistenceWriter.run_maintenance(DateTime.utc_now())
    schedule_next()
    {:noreply, state}
  end

  defp schedule_next do
    Process.send_after(self(), :run_retention, millis_until_next_3am())
  end

  defp millis_until_next_3am do
    now = NaiveDateTime.from_erl!(:calendar.local_time())
    today = NaiveDateTime.to_date(now)
    target = NaiveDateTime.new!(today, ~T[03:00:00])

    next_target =
      if NaiveDateTime.compare(now, target) == :lt do
        target
      else
        today
        |> Date.add(1)
        |> NaiveDateTime.new!(~T[03:00:00])
      end

    NaiveDateTime.diff(next_target, now, :millisecond)
  end
end
