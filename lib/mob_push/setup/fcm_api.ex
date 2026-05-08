defmodule MobPush.Setup.FcmApi do
  @moduledoc false
  # Firebase and Google Cloud REST API calls for the FCM setup wizard.
  # All functions are pure (take a token arg, make HTTP calls, return results).

  alias MobPush.Setup.HTTP

  @firebase "https://firebase.googleapis.com/v1beta1"
  @crm "https://cloudresourcemanager.googleapis.com/v1"
  @service_usage "https://serviceusage.googleapis.com/v1"
  @iam "https://iam.googleapis.com/v1"
  @fcm_service "fcm.googleapis.com"
  @sa_account_id "mob-fcm"
  @fcm_role "roles/firebase.sdkAdminServiceAgent"

  # ── Firebase projects ──────────────────────────────────────────────────────

  @doc "Lists Firebase projects the token has access to."
  @spec list_firebase_projects(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_firebase_projects(token) do
    case HTTP.get("#{@firebase}/projects?pageSize=100", HTTP.json_headers(token)) do
      {:ok, %{"results" => projects}} -> {:ok, projects}
      {:ok, _} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  @doc """
  Creates a new GCP project and adds Firebase to it.
  Returns `{:ok, project_id}` when both operations complete.
  """
  @spec create_firebase_project(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_firebase_project(token, project_id, display_name) do
    body = Jason.encode!(%{"projectId" => project_id, "name" => display_name})

    with {:ok, op} <- HTTP.post("#{@crm}/projects", HTTP.json_headers(token), body),
         :ok <- poll_crm_operation(token, op["name"]),
         {:ok, _} <- add_firebase_to_project(token, project_id) do
      {:ok, project_id}
    end
  end

  defp add_firebase_to_project(token, project_id) do
    case HTTP.post("#{@firebase}/projects/#{project_id}:addFirebase", HTTP.json_headers(token), "{}") do
      {:ok, %{"name" => op_name}} -> poll_firebase_operation(token, op_name)
      {:ok, resp} -> {:ok, resp}
      {:error, _} = err -> err
    end
  end

  # ── Android apps ──────────────────────────────────────────────────────────

  @doc "Lists Android apps registered in the Firebase project."
  @spec list_android_apps(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_android_apps(token, project_id) do
    case HTTP.get("#{@firebase}/projects/#{project_id}/androidApps", HTTP.json_headers(token)) do
      {:ok, %{"apps" => apps}} -> {:ok, apps}
      {:ok, _} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  @doc """
  Registers an Android app in the Firebase project.
  Returns `{:ok, app_id}`.
  """
  @spec register_android_app(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def register_android_app(token, project_id, package_name, display_name) do
    body = Jason.encode!(%{"packageName" => package_name, "displayName" => display_name})
    url = "#{@firebase}/projects/#{project_id}/androidApps"

    case HTTP.post(url, HTTP.json_headers(token), body) do
      {:ok, %{"name" => op_name}} ->
        with {:ok, result} <- poll_firebase_operation(token, op_name) do
          {:ok, result["appId"]}
        end

      {:ok, %{"appId" => app_id}} ->
        {:ok, app_id}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Downloads the google-services.json config for an Android app.
  Returns `{:ok, json_string}`.
  """
  @spec get_android_app_config(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_android_app_config(token, project_id, app_id) do
    url = "#{@firebase}/projects/#{project_id}/androidApps/#{app_id}/config"

    case HTTP.get(url, HTTP.json_headers(token)) do
      {:ok, %{"configFileContents" => b64}} ->
        case Base.decode64(b64) do
          {:ok, json} -> {:ok, json}
          :error -> {:error, "Could not base64-decode google-services.json content"}
        end

      {:ok, resp} ->
        {:error, "Unexpected config response: #{inspect(resp)}"}

      {:error, _} = err ->
        err
    end
  end

  # ── FCM API enable ─────────────────────────────────────────────────────────

  @doc """
  Enables the FCM HTTP v1 API in the project.
  Requires the numeric project number (from the Firebase project resource).
  """
  @spec enable_fcm_api(String.t(), String.t()) :: :ok | {:error, String.t()}
  def enable_fcm_api(token, project_number) do
    url = "#{@service_usage}/projects/#{project_number}/services/#{@fcm_service}:enable"

    case HTTP.post(url, HTTP.json_headers(token), "{}") do
      {:ok, %{"name" => op_name}} -> poll_service_usage_operation(token, op_name)
      {:ok, %{"done" => true}} -> :ok
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ── Service account ────────────────────────────────────────────────────────

  @doc """
  Creates the mob-fcm service account. Returns `{:ok, email}`.
  If the account already exists (HTTP 409), returns its email without error.
  """
  @spec create_service_account(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_service_account(token, project_id) do
    body =
      Jason.encode!(%{
        "accountId" => @sa_account_id,
        "serviceAccount" => %{"displayName" => "Mob FCM Publisher"}
      })

    url = "#{@iam}/projects/#{project_id}/serviceAccounts"

    case HTTP.post(url, HTTP.json_headers(token), body) do
      {:ok, %{"email" => email}} ->
        {:ok, email}

      {:error, "HTTP 409: " <> _} ->
        {:ok, "#{@sa_account_id}@#{project_id}.iam.gserviceaccount.com"}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Binds `roles/firebase.sdkAdminServiceAgent` to the service account
  at the project level. Fetches the current policy, adds the binding,
  and sets it back.
  """
  @spec bind_fcm_role(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def bind_fcm_role(token, project_id, sa_email) do
    get_url = "#{@crm}/projects/#{project_id}:getIamPolicy"
    set_url = "#{@crm}/projects/#{project_id}:setIamPolicy"

    with {:ok, policy} <- HTTP.post(get_url, HTTP.json_headers(token), "{}") do
      bindings = Map.get(policy, "bindings", [])
      new_binding = %{"role" => @fcm_role, "members" => ["serviceAccount:#{sa_email}"]}

      updated_bindings =
        case Enum.find_index(bindings, &(&1["role"] == @fcm_role)) do
          nil ->
            bindings ++ [new_binding]

          idx ->
            existing = Enum.at(bindings, idx)
            members = Enum.uniq(existing["members"] ++ ["serviceAccount:#{sa_email}"])
            List.replace_at(bindings, idx, %{existing | "members" => members})
        end

      updated_policy = %{policy | "bindings" => updated_bindings}
      body = Jason.encode!(%{"policy" => updated_policy})

      case HTTP.post(set_url, HTTP.json_headers(token), body) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Creates a JSON key for the service account and saves it to disk.
  Returns `{:ok, path}`.
  """
  @spec create_and_save_key(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def create_and_save_key(token, project_id, sa_email, filename) do
    url = "#{@iam}/projects/#{project_id}/serviceAccounts/#{sa_email}/keys"

    case HTTP.post(url, HTTP.json_headers(token), "{}") do
      {:ok, %{"privateKeyData" => b64}} ->
        save_key_file(b64, filename)

      {:ok, resp} ->
        {:error, "Unexpected key response: #{inspect(resp)}"}

      {:error, _} = err ->
        err
    end
  end

  @doc "Saves a base64-encoded service account JSON key to ~/.mob/keys/. Pure IO."
  @spec save_key_file(String.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def save_key_file(b64_json, filename) do
    dir = Path.expand("~/.mob/keys")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{filename}.json")

    with {:ok, json_bytes} <- Base.decode64(b64_json, padding: true),
         :ok <- File.write(path, json_bytes),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      :error -> {:error, "Could not base64-decode the key data returned by Google"}
      {:error, reason} -> {:error, "Could not write key file: #{inspect(reason)}"}
    end
  end

  # ── Project number lookup ──────────────────────────────────────────────────

  @doc "Returns the numeric project number for a Firebase project."
  @spec get_project_number(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_project_number(token, project_id) do
    case HTTP.get("#{@firebase}/projects/#{project_id}", HTTP.json_headers(token)) do
      {:ok, %{"projectNumber" => n}} -> {:ok, to_string(n)}
      {:ok, resp} -> {:error, "No projectNumber in response: #{inspect(resp)}"}
      {:error, _} = err -> err
    end
  end

  # ── Parsing helpers (pure — used for testing) ──────────────────────────────

  @doc "Extracts `{project_id, display_name}` pairs from a Firebase projects list response."
  @spec parse_projects(map()) :: [{String.t(), String.t()}]
  def parse_projects(%{"results" => results}) do
    Enum.map(results, fn p ->
      id = p["projectId"] || String.replace_prefix(p["name"] || "", "projects/", "")
      {id, p["displayName"] || id}
    end)
  end

  def parse_projects(_), do: []

  # ── Operation polling ──────────────────────────────────────────────────────

  defp poll_firebase_operation(token, op_name, attempts \\ 0)
  defp poll_firebase_operation(_token, op_name, 20), do: {:error, "Timed out waiting for #{op_name}"}

  defp poll_firebase_operation(token, op_name, attempts) do
    url = "#{@firebase}/#{op_name}"

    case HTTP.get(url, HTTP.json_headers(token)) do
      {:ok, %{"done" => true, "error" => err}} -> {:error, "Operation failed: #{inspect(err)}"}
      {:ok, %{"done" => true, "response" => resp}} -> {:ok, resp}
      {:ok, %{"done" => true}} -> {:ok, %{}}
      {:ok, _} ->
        Process.sleep(3_000 + attempts * 1_000)
        poll_firebase_operation(token, op_name, attempts + 1)
      {:error, _} = err -> err
    end
  end

  defp poll_crm_operation(token, op_name, attempts \\ 0)
  defp poll_crm_operation(_token, op_name, 20), do: {:error, "Timed out waiting for #{op_name}"}

  defp poll_crm_operation(token, op_name, attempts) do
    url = "#{@crm}/#{op_name}"

    case HTTP.get(url, HTTP.json_headers(token)) do
      {:ok, %{"done" => true, "error" => err}} -> {:error, "Operation failed: #{inspect(err)}"}
      {:ok, %{"done" => true}} -> :ok
      {:ok, _} ->
        Process.sleep(3_000 + attempts * 1_000)
        poll_crm_operation(token, op_name, attempts + 1)
      {:error, _} = err -> err
    end
  end

  defp poll_service_usage_operation(token, op_name, attempts \\ 0)
  defp poll_service_usage_operation(_token, op_name, 20), do: {:error, "Timed out waiting for #{op_name}"}

  defp poll_service_usage_operation(token, op_name, attempts) do
    url = "#{@service_usage}/#{op_name}"

    case HTTP.get(url, HTTP.json_headers(token)) do
      {:ok, %{"done" => true, "error" => err}} -> {:error, "Operation failed: #{inspect(err)}"}
      {:ok, %{"done" => true}} -> :ok
      {:ok, _} ->
        Process.sleep(3_000 + attempts * 1_000)
        poll_service_usage_operation(token, op_name, attempts + 1)
      {:error, _} = err -> err
    end
  end
end
