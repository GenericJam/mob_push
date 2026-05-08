defmodule MobPush.Setup.ApnsWizard do
  @moduledoc false
  # Interactive wizard for APNs credential setup. Called by Mix.Tasks.MobPush.Setup.Apns.

  alias MobPush.Setup.XcodeParser

  @apple_keys_url "https://developer.apple.com/account/resources/authkeys/add"
  @keys_dir "~/.mob/keys"
  @watch_timeout_ms 120_000

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    shell = Mix.shell()
    dry_run = Keyword.get(opts, :dry_run, false)

    unless File.exists?("mix.exs") do
      Mix.raise("No mix.exs found. Run mix mob_push.setup.apns from your project root.")
    end

    shell.info([:bright, "\n=== Mob APNs Setup ===\n", :reset])

    bundle_id =
      Keyword.get(opts, :bundle_id) ||
        XcodeParser.detect_bundle_id() ||
        prompt_value(shell, "Bundle ID (e.g. com.example.myapp)")

    team_id =
      Keyword.get(opts, :team_id) ||
        XcodeParser.detect_team_id() ||
        prompt_value(shell, "Team ID (10-char, from Apple Developer → Membership)")

    shell.info("[auto-detected] Bundle ID: #{bundle_id}")
    shell.info("[auto-detected] Team ID:   #{team_id}\n")

    if dry_run do
      dry_run_narrate(shell, bundle_id, team_id)
    else
      wizard_steps(shell, bundle_id, team_id)
    end
  end

  # ── Dry run ────────────────────────────────────────────────────────────────

  defp dry_run_narrate(shell, _bundle_id, _team_id) do
    shell.info("(dry run — no API calls will be made)\n")

    shell.info([:cyan, "\n── Step 1/3: Create APNs Auth Key ──", :reset])
    shell.info("  → Opens #{@apple_keys_url}")
    shell.info("  → Watches ~/Downloads for AuthKey_*.p8 (#{div(@watch_timeout_ms, 1000)}s)")
    shell.info("  → Moves key to #{@keys_dir}/")

    shell.info([:cyan, "\n── Step 2/3: APNs environment ──", :reset])
    shell.info("  → Prompts: sandbox or production?")

    shell.info([:cyan, "\n── Step 3/3: Write config ──", :reset])
    shell.info("  → Appends APNs config block to config/runtime.exs")

    shell.info("\n=== Dry run complete ===\n")
    :ok
  end

  # ── Wizard ─────────────────────────────────────────────────────────────────

  defp wizard_steps(shell, bundle_id, team_id) do
    app_name = bundle_id |> String.split(".") |> List.last()

    result =
      with {:ok, {key_id, key_path}} <- step_download_key(shell, app_name),
           {:ok, env} <- step_choose_env(shell),
           :ok <- step_write_config(shell, bundle_id, team_id, key_id, key_path, env) do
        print_success(shell, bundle_id, team_id, key_id, key_path, env)
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        shell.info([:red, "\n✗ #{reason}", :reset])
        Mix.raise("APNs setup failed: #{reason}")
    end
  end

  # ── Step 1: Download .p8 key ───────────────────────────────────────────────

  defp step_download_key(shell, app_name) do
    shell.info([:cyan, "\n── Step 1/3: Create APNs Auth Key ──\n", :reset])
    shell.info("  Opening Apple Developer portal → Keys page...")
    shell.info("  #{@apple_keys_url}\n")
    shell.info("  In the page that just opened:")
    shell.info("    1. Enter a name, e.g. \"#{String.capitalize(app_name)} APNs\"")
    shell.info("    2. Tick \"Apple Push Notifications service (APNs)\"")
    shell.info("    3. Click Continue → Register")
    shell.info("    4. Click Download\n")

    open_browser(@apple_keys_url)

    shell.info("  Watching ~/Downloads for AuthKey_*.p8... (#{div(@watch_timeout_ms, 1000)}s)")

    case watch_for_p8_download(@watch_timeout_ms) do
      {:ok, src_path} ->
        move_key(shell, src_path, app_name)

      {:error, :timeout} ->
        {:error,
         "Timed out waiting for AuthKey_*.p8. Click Download in the browser before the timeout."}
    end
  end

  defp move_key(shell, src_path, app_name) do
    filename = Path.basename(src_path)
    key_id = filename |> Path.basename(".p8") |> String.replace_prefix("AuthKey_", "")
    dest_dir = Path.expand(@keys_dir)
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, "#{app_name}-apns-#{filename}")

    with :ok <- File.cp(src_path, dest_path),
         :ok <- File.chmod(dest_path, 0o600),
         :ok <- File.rm(src_path) do
      shell.info([:green, "  ✓ Detected: #{filename}", :reset])
      shell.info([:green, "  ✓ Moved to #{dest_path}", :reset])
      {:ok, {key_id, dest_path}}
    else
      {:error, reason} ->
        {:error, "Could not move key file: #{inspect(reason)}"}
    end
  end

  # ── Step 2: APNs environment ───────────────────────────────────────────────

  defp step_choose_env(shell) do
    shell.info([:cyan, "\n── Step 2/3: APNs environment ──\n", :reset])

    env =
      case shell.prompt("  sandbox or production? [sandbox]: ") |> String.trim() do
        "production" -> :production
        _ -> :sandbox
      end

    shell.info([:green, "  ✓ #{env}", :reset])
    {:ok, env}
  end

  # ── Step 3: Write config ───────────────────────────────────────────────────

  defp step_write_config(shell, bundle_id, team_id, key_id, key_path, env) do
    shell.info([:cyan, "\n── Step 3/3: Write config ──\n", :reset])
    runtime_exs = "config/runtime.exs"
    block = config_block(bundle_id, team_id, key_id, key_path, env)

    cond do
      File.exists?(runtime_exs) ->
        existing = File.read!(runtime_exs)

        if String.contains?(existing, "mob_push") and String.contains?(existing, ":apns") do
          shell.info([
            :yellow,
            "  ⚠  #{runtime_exs} already has APNs config — skipping write. Edit it manually.",
            :reset
          ])

          :ok
        else
          File.write!(runtime_exs, existing <> "\n" <> block)
          shell.info([:green, "  ✓ Appended to #{runtime_exs}", :reset])
          :ok
        end

      File.exists?("config") ->
        File.write!(runtime_exs, "import Config\n\n" <> block)
        shell.info([:green, "  ✓ Created #{runtime_exs}", :reset])
        :ok

      true ->
        shell.info("  (no config/ directory found — paste the config snippet manually)")
        :ok
    end
  end

  # ── Config ─────────────────────────────────────────────────────────────────

  defp print_success(shell, bundle_id, team_id, key_id, key_path, env) do
    shell.info([:bright, "\n=== Setup complete! ===\n", :reset])
    shell.info(config_snippet(bundle_id, team_id, key_id, key_path, env))
  end

  defp config_block(bundle_id, team_id, key_id, key_path, env) do
    """
    # iOS push notifications (APNs)
    config :mob_push, :apns,
      key_id:    System.get_env("APNS_KEY_ID",    #{inspect(key_id)}),
      team_id:   System.get_env("APNS_TEAM_ID",   #{inspect(team_id)}),
      bundle_id: System.get_env("APNS_BUNDLE_ID", #{inspect(bundle_id)}),
      key_file:  System.get_env("APNS_KEY_FILE",  #{inspect(key_path)}),
      env:       #{env_expr(env)}
    """
  end

  defp config_snippet(bundle_id, team_id, key_id, key_path, env) do
    """
      config :mob_push, :apns,
        key_id:    "#{key_id}",
        team_id:   "#{team_id}",
        bundle_id: "#{bundle_id}",
        key_file:  System.get_env("APNS_KEY_FILE", "#{key_path}"),
        env:       #{env_expr(env)}
    """
  end

  defp env_expr(:production), do: "if(config_env() == :prod, do: :production, else: :sandbox)"
  defp env_expr(:sandbox), do: ":sandbox"

  # ── Downloads watcher ──────────────────────────────────────────────────────

  @doc "Watches ~/Downloads for AuthKey_*.p8. Returns {:ok, path} or {:error, :timeout}."
  @spec watch_for_p8_download(non_neg_integer()) :: {:ok, Path.t()} | {:error, :timeout}
  def watch_for_p8_download(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    downloads = Path.expand("~/Downloads")
    watch_loop(downloads, deadline)
  end

  defp watch_loop(dir, deadline) do
    pattern = Regex.compile!("^AuthKey_[A-Z0-9]{10}\\.p8$")

    match =
      case File.ls(dir) do
        {:ok, files} -> Enum.find(files, &Regex.match?(pattern, &1))
        {:error, _} -> nil
      end

    cond do
      match ->
        {:ok, Path.join(dir, match)}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(2_000)
        watch_loop(dir, deadline)
    end
  end

  # ── Browser ────────────────────────────────────────────────────────────────

  defp open_browser(url) do
    {bin, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", url]}
      end

    case System.find_executable(bin) do
      nil -> :ok
      _ -> System.cmd(bin, args, stderr_to_stdout: true)
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp prompt_value(shell, label) do
    shell.prompt("  #{label}: ") |> String.trim()
  end
end
