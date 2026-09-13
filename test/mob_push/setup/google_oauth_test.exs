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
end
