defmodule ExShopifyApp.AccessToken.Repo do
  @moduledoc """
  Ecto-backed, cross-node-safe store for Shopify offline access tokens.

  Mix this into a module in the host application, pointing it at the app's `Ecto.Repo`:

      defmodule MyApp.ShopifyAccessTokens do
        use ExShopifyApp.AccessToken.Repo,
          repo: MyApp.Repo
      end

  The generated module implements the `ExShopifyApp.AccessToken.Store` behaviour and
  exposes:

    * `fetch_token/1` — read the stored token, or `{:error, :no_token}`.
    * `put_token/2` — upsert a token by `shopify_domain` (initial install / re-auth).
    * `valid_token/2` — the safe primary API: returns a usable token, refreshing under
      a lock only when necessary (see below).
    * `refresh_token/2` — run a locked refresh *decision* for a shop: under the row
      lock it re-reads the token and only calls Shopify if a refresh is still needed,
      otherwise it returns the already-current stored token.
    * `migrate_token/2` — run a locked, idempotent migration of a stored lifetime
      (non-expiring) offline token to an expiring one, under the same row lock; a token
      that already carries expiry data is returned unchanged with no Shopify call.

  ## Safety model

  Refreshing rotates **both** the access and refresh tokens, so `refresh_token/2` runs
  inside `Repo.transaction/2` under a `SELECT ... FOR UPDATE` row lock and persists the
  new token before the transaction commits, serializing concurrent refreshes across
  nodes. The error taxonomy, telemetry, the host-app migration contract, and the
  unavoidable post-response crash window are covered in the README and this module
  documentation.

  ## `valid_token/2` decision table

    * No row → `{:error, :no_token}`.
    * Refresh token expired → `{:error, :reauthorization_required}` (no HTTP call).
    * Fresh token → returned as-is (no lock, no HTTP call).
    * Hard-expired token → blocking locked refresh.
    * Stale token → locked refresh; on failure, returns `{:error, reason}` by default.
      Pass `stale_while_error: true` to return the still-valid old token (with
      telemetry) when the refresh fails but the token is not yet hard-expired.

  ## Options

    * `:skew` — hard-expiry skew in seconds (see `ExShopifyApp.AccessToken.Token.expired?/3`).
    * `:soft_window` — keyword opts for the soft window (see `Token.stale?/3`).
    * `:timeout` — transaction timeout in milliseconds.
    * `:lock_timeout` — `SET LOCAL lock_timeout` in milliseconds; on timeout the call
      returns `{:error, {:lock_timeout, reason}}`.
    * `:stale_while_error` — see `valid_token/2` above (default `false`).
    * `:refresh_token_window` — seconds before *refresh-token* expiry at which a
      refresh is forced even while the access token is fresh (default `nil` —
      disabled). Drives heartbeat rotation; failures fall back like the stale
      window.
  """

  import Ecto.Query, only: [from: 2]

  alias ExShopifyApp.AccessToken
  alias ExShopifyApp.AccessToken.Token
  alias ExShopifyApp.AccessToken.RefreshResult
  alias ExShopifyApp.AccessToken.Repo.Options
  alias ExShopifyApp.AccessToken.Telemetry

  @doc false
  defmacro __using__(opts) do
    repo =
      Keyword.get(opts, :repo) ||
        raise ArgumentError, "use ExShopifyApp.AccessToken.Repo requires a :repo option"

    quote do
      @behaviour ExShopifyApp.AccessToken.Store
      @__repo unquote(repo)

      @impl ExShopifyApp.AccessToken.Store
      def fetch_token(shopify_domain) do
        ExShopifyApp.AccessToken.Repo.fetch_token(@__repo, shopify_domain)
      end

      @impl ExShopifyApp.AccessToken.Store
      def put_token(shopify_domain, token) do
        ExShopifyApp.AccessToken.Repo.put_token(@__repo, shopify_domain, token)
      end

      @impl ExShopifyApp.AccessToken.Store
      def refresh_token(shop, opts \\ []) do
        ExShopifyApp.AccessToken.Repo.refresh_token(@__repo, shop, opts)
      end

      @impl ExShopifyApp.AccessToken.Store
      def migrate_token(shop, opts \\ []) do
        ExShopifyApp.AccessToken.Repo.migrate_token(@__repo, shop, opts)
      end

      @impl ExShopifyApp.AccessToken.Store
      def valid_token(shop, opts \\ []) do
        ExShopifyApp.AccessToken.Repo.valid_token(@__repo, shop, opts)
      end
    end
  end

  @typedoc "A shop reference carrying at least its `:shopify_domain`."
  @type shop :: %{shopify_domain: String.t()}

  @doc "Fetch the stored token for a shop domain via `repo`."
  @spec fetch_token(module(), String.t()) :: {:ok, Token.t()} | {:error, :no_token}
  def fetch_token(repo, shopify_domain) do
    domain = Token.normalize_domain(shopify_domain)

    case repo.get(Token, domain) do
      nil -> {:error, :no_token}
      %Token{} = token -> {:ok, token}
    end
  end

  @doc "Upsert `token` by `shopify_domain` via `repo`."
  @spec put_token(module(), String.t(), Token.t()) :: :ok | {:error, term()}
  def put_token(repo, shopify_domain, %Token{} = token) do
    attrs =
      token
      |> Map.take(Token.castable())
      |> Map.put(:shopify_domain, Token.normalize_domain(shopify_domain))

    %Token{}
    |> Token.changeset(attrs)
    |> repo.insert(on_conflict: {:replace, Token.replaceable()}, conflict_target: :shopify_domain)
    |> case do
      {:ok, _stored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return a usable token for `shop`, refreshing under a lock only when necessary.

  See the module docs for the decision table and options.
  """
  @spec valid_token(module(), shop(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def valid_token(repo, shop, opts \\ []) do
    domain = Token.normalize_domain(shop.shopify_domain)
    now = DateTime.utc_now()

    case fetch_token(repo, domain) do
      {:error, _} = error ->
        error

      {:ok, token} ->
        cond do
          Token.refresh_token_expired?(token, now) ->
            {:error, :reauthorization_required}

          Token.expired?(token, now, Options.skew(opts)) ->
            refresh_token(repo, shop, opts)

          Token.stale?(token, now, Options.soft_window(opts)) ->
            case refresh_token(repo, shop, opts) do
              {:ok, refreshed} -> {:ok, refreshed}
              {:error, reason} -> stale_fallback(token, reason, opts)
            end

          true ->
            {:ok, token}
        end
    end
  end

  @doc """
  Run the locked refresh decision for `shop` via `repo`.

  This does not unconditionally call Shopify. Inside a `Repo.transaction/2` it takes a
  `SELECT ... FOR UPDATE` lock on the shop's row, re-reads the token, and:

    * returns `{:ok, token}` with **no** Shopify call if the token is no longer
      stale/expired (e.g. a concurrent caller already refreshed it while we waited on
      the lock — this is what collapses many concurrent callers into a single refresh);
    * otherwise calls Shopify and synchronously persists the new token before the
      transaction commits.

  Emits `[:ex_shopify_app, :access_token, :refresh]` `:start`/`:stop`/`:exception`
  telemetry. See `docs/access-token-refresh-safety.md` for the error taxonomy.
  """
  @spec refresh_token(module(), shop(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def refresh_token(repo, shop, opts \\ []) do
    domain = Token.normalize_domain(shop.shopify_domain)
    with_refresh_telemetry(domain, fn -> locked_refresh(repo, shop, domain, opts) end)
  end

  @doc """
  Run the locked migration decision for `shop` via `repo`.

  Migrates a stored lifetime (non-expiring) offline token to an expiring one under the
  same per-shop, cross-node lock as `refresh_token/3`. Inside a `Repo.transaction/2` it
  takes a `SELECT ... FOR UPDATE` lock on the shop's row, re-reads the token, and:

    * returns `{:error, :no_token}` when no row exists;
    * returns `{:ok, token}` with **no** Shopify call when the token already carries
      expiry data — it has already been migrated (e.g. a concurrent caller migrated it
      while this one waited on the lock), making the migration idempotent;
    * otherwise exchanges the lifetime token for an expiring one via
      `ExShopifyApp.AccessToken.migrate/2` and synchronously persists the new token
      (rotating `refresh_generation`) before the transaction commits.

  Shares the refresh telemetry span and error taxonomy; see `refresh_token/3` and
  `docs/access-token-refresh-safety.md`.
  """
  @spec migrate_token(module(), shop(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def migrate_token(repo, shop, opts \\ []) do
    shop = %{shop | shopify_domain: Token.normalize_domain(shop.shopify_domain)}
    with_refresh_telemetry(shop.shopify_domain, fn -> locked_migrate(repo, shop, opts) end)
  end

  # Wraps a locked, single-rotation token operation in the refresh telemetry span and
  # the shared lock-timeout / crash classification. Migration reuses this: it is the
  # same locked operation with an identical error taxonomy.
  defp with_refresh_telemetry(domain, fun) when is_function(fun, 0) do
    meta = %{shopify_domain: domain}
    start_time = Telemetry.refresh_start(meta)

    try do
      result = fun.()
      Telemetry.refresh_stop(start_time, meta, result)
      result
    rescue
      exception ->
        if RefreshResult.lock_timeout?(exception) do
          result = {:error, {:lock_timeout, exception}}
          Telemetry.refresh_stop(start_time, meta, result)
          result
        else
          Telemetry.refresh_exception(start_time, meta, exception, __STACKTRACE__)
          {:error, {:refresh_crashed, exception}}
        end
    end
  end

  defp locked_refresh(repo, shop, domain, opts) do
    txn =
      repo.transaction(
        fn ->
          Options.with_lock_timeout(opts, fn ms ->
            repo.query!("SET LOCAL lock_timeout = #{ms}")
          end)

          token = lock_token(repo, domain)
          # Capture `now` only after the row lock is held: acquiring the lock can block
          # behind another refresh, and the freshness decision must reflect the time at
          # which we actually hold the row, not when we started waiting.
          now = DateTime.utc_now()

          cond do
            is_nil(token) ->
              repo.rollback(:no_token)

            Token.refresh_token_expired?(token, now) ->
              repo.rollback(:reauthorization_required)

            not refresh_needed?(token, now, opts) ->
              token

            true ->
              perform_refresh(repo, shop, token, now, domain)
          end
        end,
        Options.transaction_opts(opts)
      )

    maybe_record_refresh_error(repo, domain, txn)
    txn
  end

  defp perform_refresh(repo, shop, token, now, domain) do
    case AccessToken.refresh(shop, token.refresh_token) do
      {:ok, refreshed} ->
        # Nothing but the DB write should happen between the refresh response and the
        # commit — the new refresh token is not yet durable.
        case persist_refreshed(repo, token, refreshed, now) do
          {:ok, updated} ->
            updated

          {:error, reason} ->
            Telemetry.persistence_failed(domain, token)
            repo.rollback({:token_persistence_failed_after_refresh, reason})
        end

      {:error, reason} ->
        repo.rollback(RefreshResult.classify_error(reason))
    end
  end

  defp persist_refreshed(repo, token, refreshed, _now) do
    changeset = Token.prepare_refresh_changes(refreshed, token)

    try do
      case repo.update(changeset) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, exception}
    end
  end

  defp locked_migrate(repo, shop, opts) do
    domain = shop.shopify_domain

    txn =
      repo.transaction(
        fn ->
          Options.with_lock_timeout(opts, fn ms ->
            repo.query!("SET LOCAL lock_timeout = #{ms}")
          end)

          token = lock_token(repo, domain)

          cond do
            is_nil(token) -> repo.rollback(:no_token)
            not migration_needed?(token) -> token
            true -> perform_migrate(repo, shop, token)
          end
        end,
        Options.transaction_opts(opts)
      )

    maybe_record_refresh_error(repo, domain, txn)
    txn
  end

  defp perform_migrate(repo, shop, token) do
    case AccessToken.migrate(shop, token.access_token) do
      {:ok, migrated} ->
        case persist_refreshed(repo, token, migrated, nil) do
          {:ok, updated} ->
            updated

          {:error, reason} ->
            Telemetry.persistence_failed(shop.shopify_domain, token)
            repo.rollback({:token_persistence_failed_after_refresh, reason})
        end

      {:error, reason} ->
        repo.rollback(RefreshResult.classify_error(reason))
    end
  end

  defp migration_needed?(%Token{expires_at: nil}), do: true
  defp migration_needed?(%Token{}), do: false

  defp lock_token(repo, domain) do
    query =
      from(
        t in Token,
        where: t.shopify_domain == ^domain,
        lock: "FOR UPDATE"
      )

    repo.one(query)
  end

  defp refresh_needed?(token, now, opts) do
    Token.expired?(token, now, Options.skew(opts)) or
      Token.stale?(token, now, Options.soft_window(opts)) or
      Token.refresh_token_expiring?(token, now, Options.refresh_token_window(opts))
  end

  # `last_refresh_error` is operational metadata only; record it in a separate write so
  # it survives the rolled-back refresh transaction, and never let it block a refresh.
  defp maybe_record_refresh_error(repo, domain, {:error, {:refresh_failed, _} = reason}) do
    try do
      repo.update_all(
        from(t in Token, where: t.shopify_domain == ^domain),
        set: [
          last_refresh_error: RefreshResult.error_label(reason),
          updated_at: DateTime.utc_now()
        ]
      )
    rescue
      _ -> :ok
    end

    :ok
  end

  defp maybe_record_refresh_error(_repo, _domain, _result), do: :ok

  defp stale_fallback(token, reason, opts) do
    # A slow failed refresh may have spanned the token's hard-expiry boundary, so
    # re-check expiry against a fresh timestamp before serving the old token.
    now = DateTime.utc_now()

    if Options.stale_while_error?(opts) and not Token.expired?(token, now, Options.skew(opts)) do
      Telemetry.stale_while_error(token, reason)
      {:ok, token}
    else
      {:error, reason}
    end
  end
end
