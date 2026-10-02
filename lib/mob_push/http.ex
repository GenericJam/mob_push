defmodule MobPush.HTTP do
  @moduledoc false
  # The one place APNs and FCM make HTTP requests (MOB-318).
  #
  # Right after boot, and after Apple drops an idle connection, the HTTP/2
  # pool can have no live connection yet. Finch then fails the request
  # before sending it (`pool_not_available` since Finch 0.22, `disconnected`
  # before that). Req's default retry ignores POSTs, so without this the
  # first push after boot (often a wake) is lost.
  #
  # Only errors that guarantee the server did not process the request are
  # retried; anything else (a timeout, a connection closed mid-request, any
  # HTTP response) is returned to the caller, because a resend could
  # deliver the push twice.
  #
  # No retry is started unless it begins within @retry_budget_ms of the
  # first attempt, so a caller is held for at most that plus one attempt.
  # Finch 0.24+ itself waits up to its `:pool_timeout` (5 s) for a pool to
  # connect; such a slow failure is returned as is, not multiplied.

  # * `pool_not_available` / `disconnected`: Finch had no connection and
  #   never sent the request.
  # * `unprocessed`: the server's GOAWAY covered this stream, so it was
  #   sent but not processed (RFC 9113 §6.8).
  # * REFUSED_STREAM: the server reset the stream before any processing
  #   (RFC 9113 §8.7).
  @unprocessed_reasons [
    :pool_not_available,
    :disconnected,
    :unprocessed,
    {:server_closed_request, :refused_stream}
  ]

  # Delays 50, 100, 200, 400, 500 ms.
  @max_retries 5
  @base_delay_ms 50
  @max_delay_ms 500
  @retry_budget_ms 1_500

  @spec post(keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(options) do
    deadline = System.monotonic_time(:millisecond) + @retry_budget_ms

    [
      finch: MobPush.Finch,
      retry: &retry(&1, &2, deadline),
      max_retries: @max_retries,
      retry_log_level: :debug
    ]
    |> Keyword.merge(options)
    |> Req.new()
    |> Req.post()
  end

  defp retry(request, response_or_exception, deadline) do
    delay = retry_delay(Req.Request.get_private(request, :req_retry_count, 0))

    if unprocessed?(response_or_exception) and
         System.monotonic_time(:millisecond) + delay < deadline do
      {:delay, delay}
    else
      false
    end
  end

  defp unprocessed?(%Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in @unprocessed_reasons

  # Req <= 0.5.17 passes Finch 0.22+'s HTTP/2 errors through unconverted.
  # A map pattern, because older Finch has no such struct to compile against.
  defp unprocessed?(%{__struct__: Finch.HTTPError, module: Mint.HTTP2, reason: reason}),
    do: reason in @unprocessed_reasons

  defp unprocessed?(_response_or_exception), do: false

  defp retry_delay(retry_count),
    do: min(@base_delay_ms * Integer.pow(2, retry_count), @max_delay_ms)
end
