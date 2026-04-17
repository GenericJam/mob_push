defmodule Mix.Tasks.MobPush.Install do
  use Mix.Task

  @shortdoc "Add mob_push config stubs to your project"

  @moduledoc """
  Interactive setup for mob_push — generates config stubs for APNs (iOS) and
  FCM (Android) in your project's `config/runtime.exs`.

  Run from your project root (the directory containing `mix.exs`):

      mix mob_push.install

  ## Before you run this

  Have the following ready, or choose "skip" to insert placeholders you can fill
  in later. Neither platform is required — skip one if your app is iOS-only or
  Android-only.

  ### iOS (APNs) — from Apple Developer portal

    - **Key ID** — 10-char string, e.g. `XXXXXXXXXX`. Found in
      *Certificates, Identifiers & Profiles → Keys*.
    - **Team ID** — 10-char string from *Membership Details*.
    - **APNs Auth Key (.p8 file)** — download from *Keys*. Apple only lets you
      download it once, so keep it safe.
    - **Bundle ID** — your app's bundle identifier, e.g. `com.example.myapp`.

  ### Android (FCM) — from Firebase console

    - **Project ID** — shown in *Project Settings*.
    - **Service Account JSON** — from *Project Settings → Service Accounts →
      Generate new private key*. Download and store the JSON file.

  ## Options

    * `--ios-only`     — skip FCM prompts
    * `--android-only` — skip APNs prompts
    * `--skip-all`     — write placeholder config for both platforms and exit
  """

  @switches [ios_only: :boolean, android_only: :boolean, skip_all: :boolean]

  @apns_docs_url "https://developer.apple.com/account/resources/authkeys/list"
  @fcm_docs_url  "https://console.firebase.google.com"

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} = OptionParser.parse(argv, strict: @switches)
    shell = Mix.shell()

    unless File.exists?("mix.exs") do
      Mix.raise("No mix.exs found. Run mix mob_push.install from your project root.")
    end

    runtime_exs = "config/runtime.exs"

    unless File.exists?("config") do
      Mix.raise("No config/ directory found. Is this a Mix project?")
    end

    shell.info([:bright, "\nmob_push setup\n", :reset])
    shell.info("This will add push notification config to #{runtime_exs}.")
    shell.info("You can skip either platform now and fill in the values later.\n")

    apns_cfg =
      cond do
        opts[:skip_all] or opts[:android_only] -> :skip
        true -> prompt_apns(shell)
      end

    fcm_cfg =
      cond do
        opts[:skip_all] or opts[:ios_only] -> :skip
        true -> prompt_fcm(shell)
      end

    if apns_cfg == :skip and fcm_cfg == :skip do
      shell.info("\nSkipping both platforms — writing placeholder config.\n")
    end

    append_config(runtime_exs, apns_cfg, fcm_cfg, shell)
  end

  # ── APNs prompts ──────────────────────────────────────────────────────────

  defp prompt_apns(shell) do
    shell.info([:cyan, "── iOS (APNs) ──────────────────────────────────────────", :reset])
    shell.info("You need a .p8 auth key from the Apple Developer portal.")
    shell.info("→ #{@apns_docs_url}\n")

    if shell.yes?("Configure APNs now?") do
      %{
        key_id:    prompt_value(shell, "Key ID (10 chars, from the portal)"),
        team_id:   prompt_value(shell, "Team ID (10 chars, from Membership Details)"),
        bundle_id: prompt_value(shell, "Bundle ID (e.g. com.example.myapp)"),
        key_file:  prompt_value(shell, "Path to .p8 key file (e.g. /run/secrets/AuthKey_XXX.p8)"),
        env:       prompt_env(shell),
      }
    else
      shell.info("  → Skipping APNs. Placeholder config will be inserted.\n")
      :skip
    end
  end

  defp prompt_env(shell) do
    shell.info("")
    env_input = shell.prompt("  APNs environment — sandbox or production? [sandbox]: ") |> String.trim()
    case env_input do
      "production" -> :production
      _            -> :sandbox
    end
  end

  # ── FCM prompts ───────────────────────────────────────────────────────────

  defp prompt_fcm(shell) do
    shell.info([:cyan, "\n── Android (FCM) ───────────────────────────────────────", :reset])
    shell.info("You need a service account JSON from Firebase console.")
    shell.info("→ #{@fcm_docs_url}\n")

    if shell.yes?("Configure FCM now?") do
      %{
        project_id:          prompt_value(shell, "Firebase Project ID"),
        service_account_key: prompt_value(shell, "Path to service account JSON file"),
      }
    else
      shell.info("  → Skipping FCM. Placeholder config will be inserted.\n")
      :skip
    end
  end

  # ── Config generation ─────────────────────────────────────────────────────

  defp append_config(runtime_exs, apns_cfg, fcm_cfg, shell) do
    block = config_block(apns_cfg, fcm_cfg)

    if File.exists?(runtime_exs) do
      existing = File.read!(runtime_exs)
      if String.contains?(existing, "mob_push") do
        shell.info([:yellow, "\n⚠ #{runtime_exs} already contains mob_push config — skipping write.", :reset])
        shell.info("  Edit it manually if needed.")
        return_next_steps(shell, apns_cfg, fcm_cfg)
        :ok
      else
        File.write!(runtime_exs, existing <> "\n" <> block)
        shell.info([:green, "\n✓ Appended mob_push config to #{runtime_exs}", :reset])
        return_next_steps(shell, apns_cfg, fcm_cfg)
      end
    else
      File.write!(runtime_exs, "import Config\n\n" <> block)
      shell.info([:green, "\n✓ Created #{runtime_exs} with mob_push config", :reset])
      return_next_steps(shell, apns_cfg, fcm_cfg)
    end
  end

  defp config_block(apns_cfg, fcm_cfg) do
    [apns_block(apns_cfg), fcm_block(fcm_cfg)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp apns_block(:skip) do
    """
    # iOS push notifications (APNs)
    # Get credentials at: #{@apns_docs_url}
    config :mob_push, :apns,
      key_id:    System.get_env("APNS_KEY_ID",    "YOUR_KEY_ID"),
      team_id:   System.get_env("APNS_TEAM_ID",   "YOUR_TEAM_ID"),
      bundle_id: System.get_env("APNS_BUNDLE_ID", "com.example.yourapp"),
      key_file:  System.get_env("APNS_KEY_FILE",  "/path/to/AuthKey_XXXXXXXXXX.p8"),
      env:       if(config_env() == :prod, do: :production, else: :sandbox)
    """
  end

  defp apns_block(%{key_id: key_id, team_id: team_id, bundle_id: bundle_id, key_file: key_file, env: env}) do
    env_expr = case env do
      :production -> "if(config_env() == :prod, do: :production, else: :sandbox)"
      :sandbox    -> ":sandbox"
    end
    """
    # iOS push notifications (APNs)
    config :mob_push, :apns,
      key_id:    System.get_env("APNS_KEY_ID",    #{inspect(key_id)}),
      team_id:   System.get_env("APNS_TEAM_ID",   #{inspect(team_id)}),
      bundle_id: System.get_env("APNS_BUNDLE_ID", #{inspect(bundle_id)}),
      key_file:  System.get_env("APNS_KEY_FILE",  #{inspect(key_file)}),
      env:       #{env_expr}
    """
  end

  defp fcm_block(:skip) do
    """
    # Android push notifications (FCM HTTP v1)
    # Get credentials at: #{@fcm_docs_url}
    config :mob_push, :fcm,
      project_id:          System.get_env("FCM_PROJECT_ID",          "your-firebase-project"),
      service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY", "/path/to/service-account.json")
    """
  end

  defp fcm_block(%{project_id: project_id, service_account_key: sa_key}) do
    """
    # Android push notifications (FCM HTTP v1)
    config :mob_push, :fcm,
      project_id:          System.get_env("FCM_PROJECT_ID",          #{inspect(project_id)}),
      service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY", #{inspect(sa_key)})
    """
  end

  # ── Next steps ────────────────────────────────────────────────────────────

  defp return_next_steps(shell, apns_cfg, fcm_cfg) do
    shell.info("""

    Next steps:
    """)

    if apns_cfg == :skip do
      shell.info("""
        iOS (APNs) — fill in config/runtime.exs when you have your credentials:
          • Key ID + Team ID: #{@apns_docs_url}
          • .p8 auth key file: same page — create a key of type "APNs"
          • Bundle ID: Apple Developer portal → Identifiers
      """)
    end

    if fcm_cfg == :skip do
      shell.info("""
        Android (FCM) — fill in config/runtime.exs when you have your credentials:
          • Firebase project + service account JSON: #{@fcm_docs_url}
            Project Settings → Service Accounts → Generate new private key
      """)
    end

    shell.info("""
      In your Mob screen, handle the push token:

          def handle_info({:push_token, token}, socket) do
            platform = :rpc.call(node(), :mob_nif, :platform, [])
            MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
            {:noreply, socket}
          end

      Then send notifications from your server:

          MobPush.send(token, :ios,     %{title: "Hello", body: "World"})
          MobPush.send(token, :android, %{title: "Hello", body: "World"})

      See README.md for the full usage guide.
    """)
  end

  defp prompt_value(shell, label) do
    shell.prompt("  #{label}: ") |> String.trim()
  end
end
