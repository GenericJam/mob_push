defmodule MobPush.Setup.GoogleOAuth do
  @moduledoc false
  # OAuth2 browser-based authorization for Google APIs.
  #
  # Opens the user's default browser to Google's consent screen, then listens
  # on a random 127.0.0.1 port for the authorization code callback (Google's
  # Desktop-app loopback flow, with `state` and PKCE S256 per attempt). No
  # external CLI tools (gcloud, etc.) required.
  #
  # Modelled on MobDev.GooglePlay.OAuth — kept as a separate module so
  # mob_push remains standalone (no dep on mob_dev).
  #
  # ## OAuth client registration
  #
  # Each user must register a "Desktop app" OAuth client at:
  #   https://console.cloud.google.com/apis/credentials
  # and provide GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET.
  # Per Google's guidance for installed CLI tools, the client_secret is not
  # actually secret — the same model used by gcloud CLI.

  alias MobPush.Setup.HTTP

  @credentials_url "https://console.cloud.google.com/apis/credentials"

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"

  @fcm_scopes [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/firebase"
  ]

  @spec fcm_scopes() :: [String.t()]
  def fcm_scopes, do: @fcm_scopes

  @doc """
  Runs the browser-based OAuth2 flow and returns a bearer access token.

  Opens the user's browser to Google's consent screen, then waits up to
  `timeout_ms` milliseconds (default 120_000) for the callback redirect.

  Each call is one authorization attempt with its own random `state` and
  PKCE (S256) verifier. The loopback listener on `127.0.0.1` accepts exactly
  one callback: it must carry this attempt's `state` or the code is refused
  without being exchanged, and the listener closes before the exchange, so
  a second callback cannot connect.

  Options: `:scopes` (required), `:timeout_ms`, and the effect seams
  `:open_browser` (`(url -> :ok)`) and `:http_post` (same contract as
  `MobPush.Setup.HTTP.post/3`).

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  @spec authorize(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def authorize(opts \\ []) do
    scopes = Keyword.fetch!(opts, :scopes)
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)
    open_browser = Keyword.get(opts, :open_browser, &open_browser/1)
    http_post = Keyword.get(opts, :http_post, &HTTP.post/3)

    with {:ok, {client_id, client_secret}} <-
           validate_client_credentials(
             System.get_env("GOOGLE_OAUTH_CLIENT_ID"),
             System.get_env("GOOGLE_OAUTH_CLIENT_SECRET")
           ) do
      HTTP.ensure_started!()
      attempt = new_attempt()

      with {:ok, listener} <- listen_loopback(),
           {:ok, code, redirect_uri} <-
             sign_in(listener, client_id, scopes, attempt, open_browser, timeout_ms),
           {:ok, tokens} <-
             exchange_code(http_post, client_id, client_secret, code, redirect_uri, attempt) do
        {:ok, tokens["access_token"]}
      end
    end
  end

  @doc false
  @spec validate_client_credentials(String.t() | nil, String.t() | nil) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def validate_client_credentials(client_id, client_secret) do
    missing =
      [
        {"GOOGLE_OAUTH_CLIENT_ID", client_id},
        {"GOOGLE_OAUTH_CLIENT_SECRET", client_secret}
      ]
      |> Enum.filter(fn {_name, value} ->
        not is_binary(value) or String.trim(value) == "" or
          String.starts_with?(String.trim(value), "TODO")
      end)
      |> Enum.map_join(" and ", &elem(&1, 0))

    if missing == "" do
      {:ok, {String.trim(client_id), String.trim(client_secret)}}
    else
      {:error,
       "FCM setup requires your own Google OAuth Desktop app client; mob_push does not " <>
         "ship a shared client. Create one at #{@credentials_url}, then set #{missing} " <>
         "before running mix mob_push.setup.fcm."}
    end
  end

  @doc """
  Builds the Google OAuth2 authorization URL for one attempt: its `state`
  and the S256 PKCE `code_challenge` of its verifier. Pure — useful for
  testing.
  """
  @spec build_auth_url(String.t(), [String.t()], String.t(), String.t(), String.t()) ::
          String.t()
  def build_auth_url(client_id, scopes, redirect_uri, state, code_challenge) do
    params = %{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(scopes, " "),
      "access_type" => "offline",
      "prompt" => "consent",
      "state" => state,
      "code_challenge" => code_challenge,
      "code_challenge_method" => "S256"
    }

    "#{@auth_url}?#{URI.encode_query(params)}"
  end

  @doc """
  The S256 PKCE challenge for `code_verifier` (RFC 7636 §4.2):
  `base64url(sha256(code_verifier))` without padding.
  """
  @spec code_challenge(String.t()) :: String.t()
  def code_challenge(code_verifier) do
    :sha256 |> :crypto.hash(code_verifier) |> Base.url_encode64(padding: false)
  end

  @doc """
  Parses the authorization code from an OAuth callback HTTP request line.

  The request line has the form:
      GET /callback?state=STATE&code=AUTH_CODE&scope=... HTTP/1.1

  The callback's `state` must equal `expected_state` (compared in constant
  time) before the code or error is looked at; a missing or different
  `state` is refused.

  Returns `{:ok, code}` or `{:error, reason}`. Pure — useful for testing.
  """
  @spec parse_callback_request(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def parse_callback_request(request_line, expected_state) do
    case Regex.run(Regex.compile!("(?:GET|HEAD) /[^?]*\\?([^ ]+)"), request_line) do
      [_, query] ->
        params = URI.decode_query(query)

        with :ok <- verify_state(params["state"], expected_state) do
          case {params["code"], params["error"]} do
            {code, nil} when is_binary(code) and code != "" ->
              {:ok, code}

            {_, error} when is_binary(error) ->
              {:error, "Google denied access: #{error}"}

            _ ->
              {:error, "No code or error in callback: #{query}"}
          end
        end

      _ ->
        {:error, "Unexpected callback request: #{String.slice(request_line, 0, 100)}"}
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  # One authorization attempt: a random `state` to tie the callback to this
  # attempt, and a PKCE verifier (32 random bytes, base64url: 43 characters
  # from the RFC 7636 unreserved set) whose challenge goes in the URL.
  defp new_attempt do
    code_verifier = random_token()

    %{
      state: random_token(),
      code_verifier: code_verifier,
      code_challenge: code_challenge(code_verifier)
    }
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp verify_state(state, expected) when is_binary(state) and state != "" do
    if secure_compare(state, expected) do
      :ok
    else
      {:error, "OAuth callback state does not match this sign-in attempt; code refused"}
    end
  end

  defp verify_state(_state, _expected) do
    {:error, "OAuth callback has no state parameter; code refused"}
  end

  # Constant-time for equal lengths (the only case that reaches the fold);
  # :crypto.hash_equals/2 needs OTP 25 and mob_push allows OTP 24.
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_a, _b), do: false

  # Bound to the loopback interface only, and opened before the browser so
  # the redirect port can't be taken in between.
  defp listen_loopback do
    case :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, listener} ->
        {:ok, listener}

      {:error, reason} ->
        {:error, "Could not start callback listener on 127.0.0.1: #{inspect(reason)}"}
    end
  end

  # The listener is closed as soon as the one callback is read, before the
  # code exchange, so no later callback can reach this attempt.
  defp sign_in(listener, client_id, scopes, attempt, open_browser, timeout_ms) do
    {:ok, port} = :inet.port(listener)
    redirect_uri = "http://127.0.0.1:#{port}/callback"
    url = build_auth_url(client_id, scopes, redirect_uri, attempt.state, attempt.code_challenge)

    with :ok <- open_browser.(url),
         {:ok, code} <- await_callback(listener, attempt.state, timeout_ms) do
      {:ok, code, redirect_uri}
    end
  after
    :gen_tcp.close(listener)
  end

  defp open_browser(url) do
    {bin, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", url]}
      end

    Mix.shell().info("  Opening browser to Google sign-in...")
    Mix.shell().info("  If it doesn't open, visit:")
    Mix.shell().info("    #{url}")
    Mix.shell().info("")

    case System.find_executable(bin) do
      nil -> :ok
      _ -> System.cmd(bin, args, stderr_to_stdout: true)
    end

    :ok
  end

  defp await_callback(listener, expected_state, timeout_ms) do
    Mix.shell().info("  Waiting for browser sign-in (#{div(timeout_ms, 1000)}s timeout)...")

    case :gen_tcp.accept(listener, timeout_ms) do
      {:ok, conn} -> handle_callback_connection(conn, expected_state)
      {:error, :timeout} -> {:error, "Timed out waiting for OAuth callback"}
      {:error, reason} -> {:error, "Callback listener error: #{inspect(reason)}"}
    end
  end

  defp handle_callback_connection(conn, expected_state) do
    result =
      case :gen_tcp.recv(conn, 0, 10_000) do
        {:ok, line} -> parse_callback_request(line, expected_state)
        {:error, reason} -> {:error, "Could not read callback: #{inspect(reason)}"}
      end

    html = callback_html(result)

    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/html\r\n" <>
        "Content-Length: #{byte_size(html)}\r\n" <>
        "Connection: close\r\n\r\n" <>
        html

    :gen_tcp.send(conn, response)
    :gen_tcp.close(conn)
    result
  end

  defp callback_html({:ok, _}) do
    "<html><body><h1>Authenticated</h1>" <>
      "<p>Sign-in successful. You can close this tab and return to the terminal.</p>" <>
      "</body></html>"
  end

  defp callback_html({:error, reason}) do
    "<html><body><h1>Authentication failed</h1>" <>
      "<p>#{html_escape(reason)}</p>" <>
      "<p>Close this tab and check the terminal for details.</p>" <>
      "</body></html>"
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp exchange_code(http_post, client_id, client_secret, code, redirect_uri, attempt) do
    body =
      URI.encode_query(%{
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code",
        "code_verifier" => attempt.code_verifier
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case http_post.(@token_url, headers, body) do
      {:ok, %{"access_token" => _} = tokens} ->
        {:ok, tokens}

      {:ok, resp} ->
        {:error, "Token exchange returned unexpected response: #{inspect(resp)}"}

      {:error, _} = err ->
        err
    end
  end
end
