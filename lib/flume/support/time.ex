defmodule Flume.Support.Time do
  import DateTime, only: [utc_now: 0, to_unix: 2, from_unix!: 2]

  def offset_from_now(offset_in_milliseconds) do
    now_micro_sec = utc_now() |> to_unix(:microseconds)
    now = now_micro_sec

    from_unix!(round(now + offset_in_milliseconds * 1_000), :microseconds)
  end

  def time_to_score(time \\ utc_now()) do
    time
    |> unix_seconds
    |> Float.to_string
  end

  def unix_seconds(time \\ utc_now()) do
    to_unix(time, :microseconds) / 1_000_000.0
  end

  def format_current_date(current_date) do
    date_time =
      %{current_date | microsecond: {0, 0}}
      |> DateTime.to_string

    date =
      current_date
      |> DateTime.to_date
      |> Date.to_string

    {date_time, date}
  end
end
