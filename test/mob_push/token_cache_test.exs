defmodule MobPush.TokenCacheTest do
  use ExUnit.Case, async: false

  alias MobPush.TokenCache

  setup do
    # Evict any cached value from previous tests
    TokenCache.evict(:test_key)
    :ok
  end

  test "calls fetch_fn on cache miss and caches result" do
    counter = :counters.new(1, [])

    fetch_fn = fn ->
      :counters.add(counter, 1, 1)
      {:ok, {"test_token", far_future()}}
    end

    assert {:ok, "test_token"} = TokenCache.get(:test_key, fetch_fn)
    assert {:ok, "test_token"} = TokenCache.get(:test_key, fetch_fn)
    # fetch_fn only called once — second call hits cache
    assert :counters.get(counter, 1) == 1
  end

  test "evict removes cached token" do
    fetch_fn = fn -> {:ok, {"tok", far_future()}} end
    assert {:ok, "tok"} = TokenCache.get(:test_key, fetch_fn)
    TokenCache.evict(:test_key)
    # Now it should call fetch_fn again
    counter = :counters.new(1, [])

    fetch_fn2 = fn ->
      :counters.add(counter, 1, 1)
      {:ok, {"tok2", far_future()}}
    end

    assert {:ok, "tok2"} = TokenCache.get(:test_key, fetch_fn2)
    assert :counters.get(counter, 1) == 1
  end

  test "expired token triggers refresh" do
    past = System.system_time(:second) - 10
    fetch_fn1 = fn -> {:ok, {"old_token", past}} end
    assert {:ok, "old_token"} = TokenCache.get(:test_key, fetch_fn1)

    fetch_fn2 = fn -> {:ok, {"new_token", far_future()}} end
    assert {:ok, "new_token"} = TokenCache.get(:test_key, fetch_fn2)
  end

  test "propagates fetch_fn errors" do
    fetch_fn = fn -> {:error, :auth_failed} end
    assert {:error, :auth_failed} = TokenCache.get(:test_key, fetch_fn)
  end

  defp far_future, do: System.system_time(:second) + 3600
end
