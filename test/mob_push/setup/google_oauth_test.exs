defmodule MobPush.Setup.GoogleOAuthTest do
  use ExUnit.Case, async: false

  alias MobPush.Setup.{FcmWizard, GoogleOAuth}

  describe "validate_client_credentials/2" do
    test "accepts and trims a configured client" do
      assert {:ok, {"client-id", "client-secret"}} =
               GoogleOAuth.validate_client_credentials(" client-id ", " client-secret ")
    end

    test "reports every missing credential before opening a browser" do
      assert {:error, reason} = GoogleOAuth.validate_client_credentials(nil, "")

      assert reason =~ "requires your own Google OAuth Desktop app client"
      assert reason =~ "does not ship a shared client"
      assert reason =~ "GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET"
      assert reason =~ "mix mob_push.setup.fcm"
    end

    test "rejects a configured client ID when its client secret is missing" do
      assert {:error, reason} =
               GoogleOAuth.validate_client_credentials("client-id", nil)

      assert reason =~ "GOOGLE_OAUTH_CLIENT_SECRET"
      refute reason =~ "set GOOGLE_OAUTH_CLIENT_ID"
    end

    test "rejects the old placeholder values" do
      assert {:error, reason} =
               GoogleOAuth.validate_client_credentials(
                 " TODO_REGISTER.apps.googleusercontent.com ",
                 " TODO_REGISTER_SECRET "
               )

      assert reason =~ "GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET"
    end
  end

  test "authorize/1 rejects missing credentials before starting OAuth" do
    env_names = ["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"]
    previous_env = Map.take(System.get_env(), env_names)
    Enum.each(env_names, &System.delete_env/1)

    try do
      assert {:error, reason} = GoogleOAuth.authorize(scopes: GoogleOAuth.fcm_scopes())
      assert reason =~ "GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET"
    after
      Enum.each(env_names, &System.delete_env/1)
      System.put_env(previous_env)
    end
  end

  describe "authorize/1 loopback flow (state + PKCE)" do
    setup do
      env_names = ["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"]
      previous_env = Map.take(System.get_env(), env_names)
      previous_shell = Mix.shell()

      System.put_env(%{
        "GOOGLE_OAUTH_CLIENT_ID" => "client-id",
        "GOOGLE_OAUTH_CLIENT_SECRET" => "secret"
      })

      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Enum.each(env_names, &System.delete_env/1)
        System.put_env(previous_env)
        Mix.shell(previous_shell)
      end)
    end

    test "the URL carries a fresh state and S256 challenge, and the exchange sends its verifier" do
      attempts =
        for _ <- 1..2 do
          task = start_authorize()
          auth = auth_params()

          assert auth["code_challenge_method"] == "S256"
          assert auth["state"] =~ ~r/\A[A-Za-z0-9_-]{32,}\z/
          assert auth["code_challenge"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/
          assert %URI{scheme: "http", host: "127.0.0.1"} = URI.parse(auth["redirect_uri"])

          callback(auth, %{"state" => auth["state"], "code" => "auth-code"})

          assert_receive {:token_exchange, body}
          exchange = URI.decode_query(body)
          verifier = exchange["code_verifier"]

          assert verifier =~ ~r/\A[A-Za-z0-9._~-]{43,128}\z/

          assert auth["code_challenge"] ==
                   Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

          assert exchange["code"] == "auth-code"
          assert exchange["redirect_uri"] == auth["redirect_uri"]

          send(task.pid, :release)
          assert {:ok, "access-token"} = Task.await(task)
          {auth["state"], verifier}
        end

      [{state1, verifier1}, {state2, verifier2}] = attempts
      assert state1 != state2
      assert verifier1 != verifier2
    end

    test "a callback without state is refused and its code never exchanged" do
      task = start_authorize()
      auth = auth_params()

      callback(auth, %{"code" => "auth-code"})

      assert {:error, _reason} = Task.await(task)
      refute_received {:token_exchange, _}
    end

    test "a callback with another state is refused, and so is the real one after it" do
      for forged <- [String.duplicate("A", 43), "short", ""] do
        task = start_authorize()
        auth = auth_params()
        refute forged == auth["state"]

        callback(auth, %{"state" => forged, "code" => "attacker-code"})

        assert {:error, _reason} = Task.await(task)
        refute_received {:token_exchange, _}
        assert {:error, :econnrefused} = connect(auth)
      end
    end

    test "a second callback is rejected while the first code is being exchanged" do
      task = start_authorize()
      auth = auth_params()

      callback(auth, %{"state" => auth["state"], "code" => "auth-code"})
      assert_receive {:token_exchange, _body}

      assert {:error, :econnrefused} = connect(auth)

      send(task.pid, :release)
      assert {:ok, "access-token"} = Task.await(task)
      refute_received {:token_exchange, _}
    end
  end

  test "FCM dry run discloses the OAuth credential prerequisite" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      assert :ok = FcmWizard.run(dry_run: true, package_name: "com.example.app")

      assert_receive {:mix_shell, :info,
                      ["  → Requires GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET"]}
    after
      Mix.shell(previous_shell)
    end
  end

  test "published FCM wizard docs disclose the required user-owned OAuth client" do
    assert {:error, setup_error} = GoogleOAuth.validate_client_credentials(nil, nil)
    assert setup_error =~ "does not ship a shared client"

    root = Path.expand("../../..", __DIR__)
    readme = File.read!(Path.join(root, "README.md"))
    task = File.read!(Path.join(root, "lib/mix/tasks/mob_push.setup.fcm.ex"))

    for document <- [readme, task] do
      assert document =~ "does not ship a shared Google OAuth client"
      assert document =~ "GOOGLE_OAUTH_CLIENT_ID"
      assert document =~ "GOOGLE_OAUTH_CLIENT_SECRET"
      refute document =~ "uses a bundled OAuth"
    end

    refute readme =~ "handle the full credential flow"
  end

  # Runs authorize/1 with its effects routed to the test: the browser URL is
  # sent as {:browser, url}; the token exchange as {:token_exchange, body},
  # then waits for :release before answering with an access token.
  defp start_authorize do
    test = self()

    Task.async(fn ->
      GoogleOAuth.authorize(
        scopes: GoogleOAuth.fcm_scopes(),
        timeout_ms: 5_000,
        open_browser: fn url ->
          send(test, {:browser, url})
          :ok
        end,
        http_post: fn "https://oauth2.googleapis.com/token", _headers, body ->
          send(test, {:token_exchange, body})

          receive do
            :release -> {:ok, %{"access_token" => "access-token"}}
          end
        end
      )
    end)
  end

  defp auth_params do
    assert_receive {:browser, url}, 5_000
    assert %URI{host: "accounts.google.com", query: query} = URI.parse(url)
    URI.decode_query(query)
  end

  defp connect(auth) do
    %URI{port: port} = URI.parse(auth["redirect_uri"])
    :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
  end

  # Plays the browser's redirect to the loopback listener and reads the reply.
  defp callback(auth, params) do
    {:ok, socket} = connect(auth)
    :ok = :gen_tcp.send(socket, "GET /callback?#{URI.encode_query(params)} HTTP/1.1\r\n\r\n")
    {:ok, _response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end
end
