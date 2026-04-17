defmodule MobPush.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Finch, name: MobPush.Finch, pools: finch_pools()},
      MobPush.TokenCache,
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MobPush.Supervisor)
  end

  # APNs requires HTTP/2. We pre-configure pools for both Apple endpoints
  # so connections are reused across calls. FCM uses HTTP/1.1 (default).
  defp finch_pools do
    %{
      "https://api.push.apple.com"         => [protocols: [:http2], count: 2, size: 10],
      "https://api.sandbox.push.apple.com" => [protocols: [:http2], count: 2, size: 10],
    }
  end
end
