defmodule MobPush.Setup.XcodeParser do
  @moduledoc false
  # Parses team_id and bundle_id from Xcode project files.
  # All parse_* functions are pure — useful for testing.

  @doc """
  Auto-detects the Apple Team ID from an Xcode project.

  Finds the first `*.xcodeproj/project.pbxproj` under `ios/` (or the current
  directory) and returns the first `DEVELOPMENT_TEAM` value found.

  Returns nil if no Xcode project is found or the value is absent.
  """
  @spec detect_team_id() :: String.t() | nil
  def detect_team_id do
    case find_pbxproj() do
      nil -> nil
      path -> path |> File.read!() |> parse_team_id()
    end
  end

  @doc """
  Auto-detects the app bundle ID from project files.

  Searches in order:
  1. `mob.exs` → `config :mob_dev, bundle_id: "..."`
  2. `ios/*.xcodeproj/project.pbxproj` → `PRODUCT_BUNDLE_IDENTIFIER`
  3. `android/app/src/main/AndroidManifest.xml` → `package="..."`

  Returns nil if not found in any source.
  """
  @spec detect_bundle_id() :: String.t() | nil
  def detect_bundle_id do
    detect_bid_from_mob_exs() ||
      detect_bid_from_pbxproj() ||
      detect_bid_from_manifest()
  end

  @doc "Parses the first DEVELOPMENT_TEAM value from pbxproj content. Pure."
  @spec parse_team_id(String.t()) :: String.t() | nil
  def parse_team_id(content) do
    case Regex.run(Regex.compile!("DEVELOPMENT_TEAM = ([A-Z0-9]{10});"), content) do
      [_, team_id] -> team_id
      _ -> nil
    end
  end

  @doc "Parses the first PRODUCT_BUNDLE_IDENTIFIER value from pbxproj content. Pure."
  @spec parse_bundle_id(String.t()) :: String.t() | nil
  def parse_bundle_id(content) do
    case Regex.run(Regex.compile!("PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);"), content) do
      [_, bundle_id] -> String.trim(bundle_id)
      _ -> nil
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp find_pbxproj do
    find_in_ios_dir() || find_in_current_dir()
  end

  defp find_in_ios_dir do
    if File.exists?("ios") do
      case File.ls("ios") do
        {:ok, entries} ->
          case Enum.find(entries, &String.ends_with?(&1, ".xcodeproj")) do
            nil ->
              nil

            xcodeproj ->
              path = Path.join(["ios", xcodeproj, "project.pbxproj"])
              if File.exists?(path), do: path
          end

        _ ->
          nil
      end
    end
  end

  defp find_in_current_dir do
    case File.ls(".") do
      {:ok, entries} ->
        case Enum.find(entries, &String.ends_with?(&1, ".xcodeproj")) do
          nil ->
            nil

          xcodeproj ->
            path = Path.join([xcodeproj, "project.pbxproj"])
            if File.exists?(path), do: path
        end

      _ ->
        nil
    end
  end

  defp detect_bid_from_mob_exs do
    if File.exists?("mob.exs") do
      content = File.read!("mob.exs")

      case Regex.run(Regex.compile!("bundle_id:\\s*\"([^\"]+)\""), content) do
        [_, id] -> id
        _ -> nil
      end
    end
  end

  defp detect_bid_from_pbxproj do
    case find_pbxproj() do
      nil -> nil
      path -> path |> File.read!() |> parse_bundle_id()
    end
  end

  defp detect_bid_from_manifest do
    manifest = "android/app/src/main/AndroidManifest.xml"

    if File.exists?(manifest) do
      content = File.read!(manifest)

      case Regex.run(Regex.compile!("package=\"([^\"]+)\""), content) do
        [_, pkg] -> pkg
        _ -> nil
      end
    end
  end
end
