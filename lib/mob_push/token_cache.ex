defmodule MobPush.TokenCache do
  @moduledoc """
  ETS-backed token cache for APNs JWT and FCM OAuth2 access tokens.

  Tokens are stored with their expiry time. Callers get a cached token
  when available and unexpired; otherwise the cache fetches a fresh one.

  This GenServer is started automatically by the MobPush application.
  You don't need to interact with it directly.
  """

  use GenServer

  @table :mob_push_tokens
  # Refresh 5 minutes before actual expiry to avoid edge cases.
  @refresh_margin_s 300

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Fetch a cached token, or call `fetch_fn/0` to produce a fresh one."
  @spec get(
          key :: term(),
          fetch_fn :: (-> {:ok, {String.t(), expires_at :: integer()}} | {:error, term()})
        ) ::
          {:ok, String.t()} | {:error, term()}
  def get(key, fetch_fn) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at - @refresh_margin_s > now ->
        {:ok, token}

      _ ->
        GenServer.call(__MODULE__, {:refresh, key, fetch_fn}, 15_000)
    end
  end

  @doc "Evict a cached token (useful when a 401 is received)."
  @spec evict(key :: term()) :: :ok
  def evict(key) do
    :ets.delete(@table, key)
    :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:refresh, key, fetch_fn}, _from, state) do
    # Double-check under the lock — another caller may have refreshed already.
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at - @refresh_margin_s > now ->
        {:reply, {:ok, token}, state}

      _ ->
        case fetch_fn.() do
          {:ok, {token, expires_at}} ->
            :ets.insert(@table, {key, token, expires_at})
            {:reply, {:ok, token}, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end
end
