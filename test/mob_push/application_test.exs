defmodule MobPush.ApplicationTest do
  # MOB-317: Finch connects every pool it is given by host as soon as it
  # starts; the `:default` pool starts only on a request. So the host keys of
  # the APNs child spec are the connections to Apple opened at boot.
  use ExUnit.Case, async: true

  @production "https://api.push.apple.com"
  @sandbox "https://api.sandbox.push.apple.com"

  defp pools(apns_config) do
    {Finch, opts} = MobPush.Application.apns_finch_child_spec(apns_config)
    opts[:pools]
  end

  defp boot_hosts(apns_config), do: apns_config |> pools() |> Map.delete(:default) |> Map.keys()

  test "no APNs pool starts at boot when :apns isn't configured" do
    assert boot_hosts(nil) == []
    assert boot_hosts([]) == []
  end

  test "only the sandbox pool starts at boot for env: :sandbox" do
    assert boot_hosts(key_id: "K", env: :sandbox) == [@sandbox]
  end

  test "sandbox is the default env, as for sends" do
    assert boot_hosts(key_id: "K") == [@sandbox]
  end

  test "only the production pool starts at boot for env: :production" do
    assert boot_hosts(key_id: "K", env: :production) == [@production]
  end

  test "every APNs pool, including one started on a later send, is HTTP/2" do
    for config <- [nil, [key_id: "K", env: :sandbox], [key_id: "K", env: :production]],
        {_host, opts} <- pools(config) do
      assert opts[:protocols] == [:http2]
    end

    assert Map.has_key?(pools(nil), :default)
  end
end
