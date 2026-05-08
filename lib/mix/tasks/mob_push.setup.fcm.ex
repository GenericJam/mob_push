defmodule Mix.Tasks.MobPush.Setup.Fcm do
  use Mix.Task

  @shortdoc "Set up Firebase Cloud Messaging credentials for Android push notifications"

  @moduledoc """
  Interactive wizard that fully provisions FCM credentials for Android push
  notifications — no Firebase console browsing required.

  Run from your project root:

      mix mob_push.setup.fcm

  The wizard will:

  1. Open your browser to Google sign-in (OAuth 2.0)
  2. Let you pick an existing Firebase project or create a new one
  3. Register your Android app and download `google-services.json`
  4. Enable the FCM HTTP v1 API
  5. Create a `mob-fcm` service account with minimal IAM permissions
  6. Generate a service-account JSON key and save it to `~/.mob/keys/`
  7. Append the config block to `config/runtime.exs`

  ## Options

    * `--dry-run` — narrate all steps without making any API calls or writing files

  ## Prerequisites

  A Google account with access to Firebase is all that's required. The wizard
  can create the Firebase project if one doesn't exist yet.

  ### Google OAuth client

  The wizard uses a bundled OAuth "Desktop app" client registered for Mob. You
  can override with environment variables if your organisation requires its own:

      export GOOGLE_OAUTH_CLIENT_ID=...
      export GOOGLE_OAUTH_CLIENT_SECRET=...
  """

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} = OptionParser.parse(argv, strict: @switches)
    MobPush.Setup.FcmWizard.run(opts)
  end
end
