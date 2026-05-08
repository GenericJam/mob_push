defmodule MobPush.Setup.FcmWizard do
  @moduledoc false
  # Interactive wizard for FCM credential setup. Called by Mix.Tasks.MobPush.Setup.Fcm.

  alias MobPush.Setup.{FcmApi, GoogleOAuth, HTTP}

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    shell = Mix.shell()
    dry_run = Keyword.get(opts, :dry_run, false)

    unless File.exists?("mix.exs") do
      Mix.raise("No mix.exs found. Run mix mob_push.setup.fcm from your project root.")
    end

    shell.info([:bright, "\n=== Mob FCM Setup ===\n", :reset])

    package_name = Keyword.get(opts, :package_name) || detect_package_name() || prompt_package(shell)
    shell.info("[auto-detected] Package name: #{package_name}\n")

    if dry_run do
      dry_run_narrate(shell, package_name)
    else
      HTTP.ensure_started!()
      wizard_steps(shell, package_name)
    end
  end

  # ── Dry run ────────────────────────────────────────────────────────────────

  defp dry_run_narrate(shell, package_name) do
    shell.info("(dry run — no API calls will be made)\n")

    shell.info([:cyan, "\n── Step 1/6: Sign in to Google ──", :reset])
    shell.info("  → Opens browser OAuth flow to accounts.google.com")

    shell.info([:cyan, "\n── Step 2/6: Select Firebase project ──", :reset])
    shell.info("  → Lists your projects; you pick one or create new")

    shell.info([:cyan, "\n── Step 3/6: Register Android app ──", :reset])
    shell.info("  → Checks if #{package_name} is already registered")
    shell.info("  → Downloads google-services.json → android/app/google-services.json")

    shell.info([:cyan, "\n── Step 4/6: Enable FCM HTTP v1 API ──", :reset])
    shell.info("  → Enables fcm.googleapis.com via Service Usage API")

    shell.info([:cyan, "\n── Step 5/6: Create service account ──", :reset])
    shell.info("  → Creates mob-fcm@<project>.iam.gserviceaccount.com")
    shell.info("  → Binds roles/firebase.sdkAdminServiceAgent")

    shell.info([:cyan, "\n── Step 6/6: Generate JSON key ──", :reset])
    shell.info("  → Saves key to ~/.mob/keys/")

    shell.info("\n=== Dry run complete ===\n")
    :ok
  end

  # ── Wizard ─────────────────────────────────────────────────────────────────

  defp wizard_steps(shell, package_name) do
    app_name = package_short_name(package_name)

    result =
      with {:ok, token} <- step_sign_in(shell),
           {:ok, project_id} <- step_select_project(shell, token),
           {:ok, _} <- step_register_app(shell, token, project_id, package_name, app_name),
           :ok <- step_enable_api(shell, token, project_id),
           {:ok, sa_email} <- step_service_account(shell, token, project_id),
           {:ok, key_path} <- step_generate_key(shell, token, project_id, sa_email, app_name) do
        finish(shell, project_id, key_path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        shell.info([:red, "\n✗ #{reason}", :reset])
        Mix.raise("FCM setup failed: #{reason}")
    end
  end

  # ── Step 1: Sign in ────────────────────────────────────────────────────────

  defp step_sign_in(shell) do
    shell.info([:cyan, "\n── Step 1/6: Sign in to Google ──", :reset])

    case GoogleOAuth.authorize(scopes: GoogleOAuth.fcm_scopes()) do
      {:ok, token} ->
        shell.info([:green, "  ✓ Signed in", :reset])
        {:ok, token}

      {:error, _} = err ->
        err
    end
  end

  # ── Step 2: Select project ─────────────────────────────────────────────────

  defp step_select_project(shell, token) do
    shell.info([:cyan, "\n── Step 2/6: Select Firebase project ──", :reset])

    with {:ok, projects} <- FcmApi.list_firebase_projects(token) do
      choose_project(shell, token, projects)
    end
  end

  defp choose_project(shell, token, []) do
    shell.info("  No Firebase projects found.")
    create_new_project(shell, token)
  end

  defp choose_project(shell, token, projects) do
    parsed =
      Enum.map(projects, fn p ->
        id = p["projectId"] || String.replace_prefix(p["name"] || "", "projects/", "")
        {id, p["displayName"] || id}
      end)

    shell.info("  Found #{length(parsed)} Firebase project(s):")

    parsed
    |> Enum.with_index(1)
    |> Enum.each(fn {{id, name}, idx} ->
      shell.info("    #{idx}. #{name} (#{id})")
    end)

    create_idx = length(parsed) + 1
    shell.info("    #{create_idx}. Create new project")

    raw = shell.prompt("  Enter number [1]: ") |> String.trim()
    choice = if raw == "", do: "1", else: raw

    case Integer.parse(choice) do
      {n, ""} when n >= 1 and n <= length(parsed) ->
        {project_id, project_name} = Enum.at(parsed, n - 1)
        shell.info([:green, "  ✓ Using: #{project_name} (#{project_id})", :reset])
        {:ok, project_id}

      {n, ""} when n == create_idx ->
        create_new_project(shell, token)

      _ ->
        {:error, "Invalid selection: #{choice}"}
    end
  end

  defp create_new_project(shell, token) do
    project_id = shell.prompt("  New project ID (e.g. my-app-12345): ") |> String.trim()
    display_name = shell.prompt("  Display name (e.g. My App): ") |> String.trim()
    shell.info("  Creating Firebase project #{project_id}... (may take up to 60s)")

    case FcmApi.create_firebase_project(token, project_id, display_name) do
      {:ok, id} ->
        shell.info([:green, "  ✓ Created Firebase project: #{id}", :reset])
        {:ok, id}

      {:error, _} = err ->
        err
    end
  end

  # ── Step 3: Register app + download config ─────────────────────────────────

  defp step_register_app(shell, token, project_id, package_name, app_name) do
    shell.info([:cyan, "\n── Step 3/6: Register Android app ──", :reset])

    with {:ok, apps} <- FcmApi.list_android_apps(token, project_id),
         {:ok, app_id} <- find_or_register(shell, token, project_id, package_name, app_name, apps),
         {:ok, json} <- FcmApi.get_android_app_config(token, project_id, app_id) do
      dest = "android/app/google-services.json"
      File.mkdir_p!("android/app")
      File.write!(dest, json)
      shell.info([:green, "  ✓ Saved #{dest}", :reset])
      {:ok, app_id}
    end
  end

  defp find_or_register(shell, token, project_id, package_name, app_name, apps) do
    case Enum.find(apps, fn a -> a["packageName"] == package_name end) do
      %{"appId" => app_id} ->
        shell.info([:green, "  ✓ Android app #{package_name} already registered", :reset])
        {:ok, app_id}

      nil ->
        shell.info("  Registering #{package_name}...")

        case FcmApi.register_android_app(token, project_id, package_name, app_name) do
          {:ok, app_id} ->
            shell.info([:green, "  ✓ Registered #{package_name}", :reset])
            {:ok, app_id}

          {:error, _} = err ->
            err
        end
    end
  end

  # ── Step 4: Enable FCM API ─────────────────────────────────────────────────

  defp step_enable_api(shell, token, project_id) do
    shell.info([:cyan, "\n── Step 4/6: Enable FCM HTTP v1 API ──", :reset])
    shell.info("  Enabling fcm.googleapis.com... (may take up to 60s)")

    with {:ok, project_number} <- FcmApi.get_project_number(token, project_id),
         :ok <- FcmApi.enable_fcm_api(token, project_number) do
      shell.info([:green, "  ✓ FCM API enabled", :reset])
      :ok
    end
  end

  # ── Step 5: Service account ────────────────────────────────────────────────

  defp step_service_account(shell, token, project_id) do
    shell.info([:cyan, "\n── Step 5/6: Create service account ──", :reset])

    with {:ok, sa_email} <- FcmApi.create_service_account(token, project_id),
         :ok <- FcmApi.bind_fcm_role(token, project_id, sa_email) do
      shell.info([:green, "  ✓ Created #{sa_email}", :reset])
      shell.info([:green, "  ✓ Granted roles/firebase.sdkAdminServiceAgent", :reset])
      {:ok, sa_email}
    end
  end

  # ── Step 6: Generate key ───────────────────────────────────────────────────

  defp step_generate_key(shell, token, project_id, sa_email, app_name) do
    shell.info([:cyan, "\n── Step 6/6: Generate JSON key ──", :reset])
    filename = "#{app_name}-fcm-service-account"

    case FcmApi.create_and_save_key(token, project_id, sa_email, filename) do
      {:ok, path} ->
        shell.info([:green, "  ✓ Key saved to #{path}", :reset])
        {:ok, path}

      {:error, _} = err ->
        err
    end
  end

  # ── Finish ─────────────────────────────────────────────────────────────────

  defp finish(shell, project_id, key_path) do
    shell.info([:bright, "\n=== Setup complete! ===\n", :reset])
    write_config(shell, project_id, key_path)
    shell.info("\nAdd this to config/runtime.exs:\n")
    shell.info(config_snippet(project_id, key_path))
    :ok
  end

  defp write_config(shell, project_id, key_path) do
    runtime_exs = "config/runtime.exs"

    cond do
      File.exists?(runtime_exs) ->
        existing = File.read!(runtime_exs)

        if String.contains?(existing, "mob_push") and String.contains?(existing, ":fcm") do
          shell.info([
            :yellow,
            "⚠  #{runtime_exs} already has FCM config — skipping write. Edit it manually.",
            :reset
          ])
        else
          File.write!(runtime_exs, existing <> "\n" <> config_block(project_id, key_path))
          shell.info([:green, "✓ Appended FCM config to #{runtime_exs}", :reset])
        end

      File.exists?("config") ->
        File.write!(runtime_exs, "import Config\n\n" <> config_block(project_id, key_path))
        shell.info([:green, "✓ Created #{runtime_exs} with FCM config", :reset])

      true ->
        shell.info("  (no config/ directory found — paste the snippet above manually)")
    end
  end

  defp config_block(project_id, key_path) do
    """
    # Android push notifications (FCM HTTP v1)
    config :mob_push, :fcm,
      project_id:          System.get_env("FCM_PROJECT_ID",          #{inspect(project_id)}),
      service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY", #{inspect(key_path)})
    """
  end

  defp config_snippet(project_id, key_path) do
    """
      config :mob_push, :fcm,
        project_id:          "#{project_id}",
        service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY",
                               "#{key_path}")
    """
  end

  # ── Package name detection ─────────────────────────────────────────────────

  @doc "Auto-detects the Android package name from project files. Returns nil if not found."
  @spec detect_package_name() :: String.t() | nil
  def detect_package_name do
    detect_pkg_from_mob_exs() || detect_pkg_from_manifest()
  end

  defp detect_pkg_from_mob_exs do
    if File.exists?("mob.exs") do
      content = File.read!("mob.exs")

      case Regex.run(Regex.compile!("bundle_id:\\s*\"([^\"]+)\""), content) do
        [_, id] -> id
        _ -> nil
      end
    end
  end

  defp detect_pkg_from_manifest do
    manifest = "android/app/src/main/AndroidManifest.xml"

    if File.exists?(manifest) do
      content = File.read!(manifest)

      case Regex.run(Regex.compile!("package=\"([^\"]+)\""), content) do
        [_, pkg] -> pkg
        _ -> nil
      end
    end
  end

  defp prompt_package(shell) do
    shell.info("  Could not auto-detect Android package name.")
    shell.prompt("  Android package name (e.g. com.example.myapp): ") |> String.trim()
  end

  defp package_short_name(package_name) do
    package_name |> String.split(".") |> List.last()
  end
end
