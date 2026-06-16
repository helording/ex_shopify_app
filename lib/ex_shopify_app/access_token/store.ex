defmodule ExShopifyApp.AccessToken.Store do
  @moduledoc """
  Behaviour for durably persisting and safely refreshing offline access tokens.

  Refreshing an expiring offline token rotates **both** the access token and the
  refresh token; Shopify invalidates the previous refresh token once it accepts the
  request. The new refresh token must therefore be persisted durably before it is
  handed back to any caller, and concurrent refreshes for one shop must be serialized
  across all processes and nodes. That serialization is inherently store-specific
  (e.g. a `SELECT ... FOR UPDATE` row lock), which is why `c:refresh_token/2` is part
  of this behaviour rather than a generic, store-agnostic manager.

  `ExShopifyApp.AccessToken.Repo` provides the production implementation backed by a
  host application's `Ecto.Repo`. Non-Ecto applications can implement this behaviour
  against any datastore that offers an equivalent cross-node lock.
  """

  alias ExShopifyApp.AccessToken.Token

  @typedoc "A shop reference carrying at least its `:shopify_domain`."
  @type shop :: %{shopify_domain: String.t()}

  @doc "Fetch the stored token for a shop domain, or `{:error, :no_token}`."
  @callback fetch_token(shopify_domain :: String.t()) ::
              {:ok, Token.t()} | {:error, term()}

  @doc "Durably persist (upsert) the token for a shop domain."
  @callback put_token(shopify_domain :: String.t(), token :: Token.t()) ::
              :ok | {:error, term()}

  @doc """
  Return a usable token for `shop`, refreshing under the lock only when necessary.

  The safe primary API: implementations read the stored token and decide whether it can
  be served as-is or must be refreshed via `c:refresh_token/2` (a fresh token is
  returned with no lock or network call). See `ExShopifyApp.AccessToken.Repo` for the
  reference implementation, decision table, and options.
  """
  @callback valid_token(shop :: shop(), opts :: keyword()) ::
              {:ok, Token.t()} | {:error, term()}

  @doc """
  Run a locked refresh *decision* for `shop` behind a per-shop, cross-node lock.

  Implementations must take the lock, re-read the token, and only call the refresh
  endpoint when a refresh is still needed — if the token is already current (e.g.
  another caller refreshed it while this one waited on the lock), the stored token is
  returned without a network call. When a refresh does happen, the new token must be
  durably persisted before it is returned. See `ExShopifyApp.AccessToken.Repo` for the
  reference implementation and error taxonomy.
  """
  @callback refresh_token(shop :: shop(), opts :: keyword()) ::
              {:ok, Token.t()} | {:error, term()}

  @doc """
  Run a locked, idempotent migration of a stored lifetime (non-expiring) offline token
  to an expiring one, behind the same per-shop, cross-node lock as `c:refresh_token/2`.

  Implementations must take the lock, re-read the token, and only call the migration
  exchange when the stored token is still a lifetime token — a token that already
  carries expiry data is returned unchanged with no network call. When a migration does
  happen, the new token must be durably persisted before it is returned.

  Optional: stores that do not support lifetime-token migration need not implement it.
  See `ExShopifyApp.AccessToken.Repo` for the reference implementation.
  """
  @callback migrate_token(shop :: shop(), opts :: keyword()) ::
              {:ok, Token.t()} | {:error, term()}

  @optional_callbacks migrate_token: 2
end
