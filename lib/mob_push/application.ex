defmodule MobPush.Application do
  @moduledoc false

  use Application

  @apns_pool [protocols: [:http2], count: 2, size: 10]

  @impl Application
  def start(_type, _args) do
    children = [
      # FCM: Finch's default HTTP/1.1 pools, started on first request.
      {Finch, name: MobPush.Finch},
      apns_finch_child_spec(Application.get_env(:mob_push, :apns)),
      MobPush.TokenCache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MobPush.Supervisor)
  end

  # APNs requires HTTP/2, so it has its own Finch whose pools are all HTTP/2.
  # Finch connects a pool listed by host as soon as it starts, and starts a
  # `:default` pool only on the first request to a host (MOB-317). So only
  # the configured env's host is listed, which keeps the first push after boot
  # off a cold connection, and nothing is listed without `:apns` config, so
  # dev and test boots of a host app don't connect to Apple. Config set or
  # changed after boot still gets an HTTP/2 pool, on its first send.
  @doc false
  @spec apns_finch_child_spec(keyword() | nil) :: {module(), keyword()}
  def apns_finch_child_spec(apns_config) do
    {Finch,
     name: MobPush.APNSFinch, pools: Map.put(apns_pools(apns_config), :default, @apns_pool)}
  end

  defp apns_pools(nil), do: %{}
  defp apns_pools([]), do: %{}
  defp apns_pools(apns_config), do: %{MobPush.APNS.base_url(apns_config) => @apns_pool}
end
