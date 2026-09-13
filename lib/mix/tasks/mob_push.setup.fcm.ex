defmodule Mix.Tasks.MobPush.Setup.Fcm do
  use Mix.Task

  @shortdoc "Set up Firebase Cloud Messaging credentials for Android push notifications"

  @moduledoc """
  Interactive wizard that provisions FCM credentials for Android push
  notifications after you configure a Google OAuth Desktop app client.

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

  You need a Google account and your own Google OAuth "Desktop app" client.
  The wizard can create the Firebase project if one doesn't exist yet, but
  `mob_push` does not ship a shared Google OAuth client.

  ### Google OAuth client

  Before running the wizard, create an OAuth 2.0 Client ID with application type
  **Desktop app** at https://console.cloud.google.com/apis/credentials, then set:

      export GOOGLE_OAUTH_CLIENT_ID=...
      export GOOGLE_OAUTH_CLIENT_SECRET=...

  If you do not want to create an OAuth client, use `mix mob_push.install` and
  configure an existing Firebase service-account key instead.
  """

  alias MobPush.Setup.FcmWizard

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} = OptionParser.parse(argv, strict: @switches)
    FcmWizard.run(opts)
  end
end
