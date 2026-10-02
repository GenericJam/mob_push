# Finch 0.22+ wraps Mint errors in Finch.HTTPError. The locked Finch predates
# it, so define a stand-in with the same fields when it's missing.
if !Code.ensure_loaded?(Finch.HTTPError) do
  defmodule Finch.HTTPError do
    defexception [:reason, :module, :source]
    @impl Exception
    def message(%{reason: reason}), do: inspect(reason)
  end
end

defmodule MobPush.TransientRetryTest do
  # MOB-318: the first APNs send after VM boot lands while the HTTP/2 pool
  # is still connecting, and Finch answers `pool_not_available` without
  # sending anything. Those errors must be retried briefly; errors where
  # the request may already have reached Apple/Google must not be.
  #
  # The HTTP layer is replaced with a scripted Req adapter installed via
  # `Req.default_options/1` (global, hence async: false).
  use ExUnit.Case, async: false

  alias MobPush.{APNS, FCM}

  setup do
    original_req = Req.default_options()
    original_apns = Application.get_env(:mob_push, :apns)
    original_fcm = Application.get_env(:mob_push, :fcm)

    on_exit(fn ->
      Req.default_options(original_req)
      restore_env(:apns, original_apns)
      restore_env(:fcm, original_fcm)
    end)

    :ok
  end

  describe "APNs" do
    setup do
      key_id = "RETRY#{System.unique_integer([:positive])}"

      Application.put_env(:mob_push, :apns,
        key_id: key_id,
        team_id: "TEAMID1234",
        bundle_id: "com.example.app",
        key_pem: ec_pem(),
        env: :sandbox
      )

      on_exit(fn -> MobPush.TokenCache.evict({:apns_jwt, key_id}) end)
      :ok
    end

    test "pool_not_available on the first attempt is retried and the push is delivered" do
      script = stub([pool_not_available(), pool_not_available(), response(200)])

      assert :ok = APNS.send("devicetoken", %{content_available: true})
      assert attempts(script) == 3
    end

    test "a pool that never becomes available returns the error within 2 s" do
      script = stub(List.duplicate(pool_not_available(), 20))

      {micros, result} = :timer.tc(fn -> APNS.send("devicetoken", %{title: "a", body: "b"}) end)

      assert {:error, %Req.HTTPError{protocol: :http2, reason: :pool_not_available}} = result
      assert attempts(script) > 1
      assert micros < 2_000_000
    end

    test "a slow pool_not_available (Finch 0.24+ already waited for the pool) is not retried" do
      script = stub([slow(pool_not_available(), 1_600), response(200)])

      assert {:error, %Req.HTTPError{reason: :pool_not_available}} =
               APNS.send("devicetoken", %{title: "a", body: "b"})

      assert attempts(script) == 1
    end

    test "no retry starts 1.5 s or later after the first attempt, counting the backoff" do
      # Four fast failures put the fifth attempt at ~750 ms; it takes 600 ms,
      # and the next backoff (500 ms) would start a sixth attempt at ~1.85 s.
      fast = List.duplicate(pool_not_available(), 4)
      script = stub(fast ++ [slow(pool_not_available(), 600), response(200)])

      assert {:error, %Req.HTTPError{reason: :pool_not_available}} =
               APNS.send("devicetoken", %{title: "a", body: "b"})

      [first | _] = starts = starts(script)
      assert Enum.all?(starts, &(&1 - first < 1_500)), "attempt offsets: #{inspect(starts)}"
    end

    test "other HTTP/2 errors the server did not process are retried" do
      for reason <- [
            :disconnected,
            :read_only,
            :unprocessed,
            {:server_closed_request, :refused_stream}
          ] do
        script = stub([http2_error(reason), response(200)])

        assert :ok = APNS.send("devicetoken", %{title: "a", body: "b"})
        assert attempts(script) == 2, "expected #{inspect(reason)} to be retried"
      end
    end

    test "unprocessed arriving as a raw Finch.HTTPError (Req <= 0.5.17 on Finch 0.22+) is retried" do
      script = stub([finch_http2_error(:unprocessed), response(200)])

      assert :ok = APNS.send("devicetoken", %{title: "a", body: "b"})
      assert attempts(script) == 2
    end

    test "errors where the request may have reached Apple are not retried (no duplicate push)" do
      for error <- [
            http2_error(:connection_closed),
            http2_error({:server_closed_request, :internal_error}),
            finch_http2_error(:connection_closed),
            %Req.TransportError{reason: :timeout},
            %Req.TransportError{reason: :closed}
          ] do
        script = stub([error, response(200)])

        assert {:error, ^error} = APNS.send("devicetoken", %{title: "a", body: "b"})
        assert attempts(script) == 1, "expected #{inspect(error)} not to be retried"
      end
    end

    test "APNs error responses are returned, not retried" do
      script = stub([response(503, %{"reason" => "ServiceUnavailable"}), response(200)])

      assert {:error, {:unexpected_status, 503, _}} =
               APNS.send("devicetoken", %{title: "a", body: "b"})

      assert attempts(script) == 1

      script = stub([response(400, %{"reason" => "BadDeviceToken"}), response(200)])

      assert {:error, {:apns_error, "BadDeviceToken"}} =
               APNS.send("devicetoken", %{title: "a", body: "b"})

      assert attempts(script) == 1
    end
  end

  describe "FCM" do
    setup do
      email = "retry#{System.unique_integer([:positive])}@example.iam.gserviceaccount.com"

      Application.put_env(:mob_push, :fcm,
        project_id: "proj",
        service_account_json: %{"client_email" => email, "private_key" => rsa_pem()}
      )

      on_exit(fn -> MobPush.TokenCache.evict({:fcm_token, email}) end)
      :ok
    end

    test "pool_not_available on the OAuth exchange and the send are retried" do
      script =
        stub([
          pool_not_available(),
          response(200, %{"access_token" => "ya29.token", "expires_in" => 3600}),
          pool_not_available(),
          response(200)
        ])

      assert :ok = FCM.send("fcmtoken", %{title: "a", body: "b"})

      assert Enum.map(requests(script), & &1.url.host) == [
               "oauth2.googleapis.com",
               "oauth2.googleapis.com",
               "fcm.googleapis.com",
               "fcm.googleapis.com"
             ]
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Installs a Req adapter that answers each request with the next scripted
  # result (a 0-arity function is called for it) and records the request
  # and its start time. Returns the recording agent.
  defp stub(results) do
    {:ok, agent} = Agent.start_link(fn -> {results, []} end)

    Req.default_options(
      adapter: fn request ->
        started = System.monotonic_time(:millisecond)

        result =
          Agent.get_and_update(agent, fn {[next | rest], seen} ->
            {next, {rest, [{started, request} | seen]}}
          end)

        {request, if(is_function(result, 0), do: result.(), else: result)}
      end
    )

    agent
  end

  defp slow(result, ms) do
    fn ->
      Process.sleep(ms)
      result
    end
  end

  defp seen(agent), do: agent |> Agent.get(&elem(&1, 1)) |> Enum.reverse()
  defp requests(agent), do: agent |> seen() |> Enum.map(&elem(&1, 1))
  defp starts(agent), do: agent |> seen() |> Enum.map(&elem(&1, 0))
  defp attempts(agent), do: length(seen(agent))

  defp pool_not_available, do: http2_error(:pool_not_available)
  defp http2_error(reason), do: %Req.HTTPError{protocol: :http2, reason: reason}

  defp finch_http2_error(reason),
    do: struct(Finch.HTTPError, module: Mint.HTTP2, reason: reason)

  defp response(status, body \\ ""), do: Req.Response.new(status: status, body: body)

  defp restore_env(key, nil), do: Application.delete_env(:mob_push, key)
  defp restore_env(key, value), do: Application.put_env(:mob_push, key, value)

  defp ec_pem do
    {_, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:ec, "P-256"}))
    pem
  end

  defp rsa_pem do
    {_, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:rsa, 2048}))
    pem
  end
end
