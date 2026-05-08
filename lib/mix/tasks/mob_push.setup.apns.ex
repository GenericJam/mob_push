defmodule Mix.Tasks.MobPush.Setup.Apns do
  use Mix.Task

  @shortdoc "Set up Apple Push Notifications credentials for iOS push notifications"

  @moduledoc """
  Interactive wizard for APNs credential setup — walks you through creating and
  installing an APNs Auth Key (.p8) without having to navigate the Apple
  Developer portal manually.

  Run from your project root:

      mix mob_push.setup.apns

  The wizard will:

  1. Auto-detect your bundle ID and team ID from the Xcode project
  2. Open the Apple Developer portal → Keys page in your browser
  3. Tell you exactly what to click (name, APNs checkbox, Download)
  4. Watch `~/Downloads` for the `.p8` file and move it to `~/.mob/keys/`
  5. Ask whether to use sandbox or production
  6. Append the config block to `config/runtime.exs`

  One click in the browser is unavoidable — Apple has no API for creating
  APNs Auth Keys.

  ## Options

    * `--dry-run` — narrate all steps without writing any files
  """

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} = OptionParser.parse(argv, strict: @switches)
    MobPush.Setup.ApnsWizard.run(opts)
  end
end
