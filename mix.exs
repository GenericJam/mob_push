defmodule MobPush.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/genericjam/mob_push"

  def project do
    [
      app: :mob_push,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Server-side push notifications for Mob apps — APNs (iOS) and FCM (Android)",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key],
      mod: {MobPush.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_url_pattern: "#{@source_url}/blob/main/%{path}#L%{line}",
      extras: [
        "README.md": [title: "Overview"],
        "plan.md": [title: "Roadmap"]
      ],
      groups_for_modules: [
        API: [MobPush],
        Internals: [MobPush.APNS, MobPush.FCM, MobPush.TokenCache],
        "Mix Tasks": ~r/Mix\.Tasks\./
      ]
    ]
  end
end
