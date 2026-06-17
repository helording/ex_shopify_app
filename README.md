# `ex_shopify_app`

Your entrypoint to create a Shopify Application in Elixir.

## Installation

Add `ex_shopify_app` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_shopify_app, "~> 1.0"}
  ]
end
```

The library uses [Ecto](https://hexdocs.pm/ecto) for the canonical access-token
schema, so `:ecto` is a required dependency. The durable store
(`ExShopifyApp.AccessToken.Repo`) runs against **your** application's `Ecto.Repo`
(and therefore your `:ecto_sql` driver) — the library itself does not pull in
`ecto_sql` or a database driver.

## Offline access tokens

Shopify's expiring offline access tokens rotate **both** the access token and the
refresh token on every refresh; the previous refresh token is invalidated as soon as
Shopify accepts the request. If the new refresh token is not durably persisted before
it is used, the merchant may have to re-authorize the app. The access-token modules are
built around that safety concern.

### 1. Run the migration

Create the `shopify_access_tokens` table. `shopify_domain` is the primary key, so there
is exactly one canonical token chain per shop/installation. Delegate to
`ExShopifyApp.AccessToken.Migrations` so the table can never drift from the schema the
library is compiled against:

```elixir
defmodule MyApp.Repo.Migrations.CreateShopifyAccessTokens do
  use Ecto.Migration

  def up, do: ExShopifyApp.AccessToken.Migrations.up()
  def down, do: ExShopifyApp.AccessToken.Migrations.down()
end
```

The migrations are versioned (PostgreSQL only; version tracking uses table comments): `up/0` runs every version up to the latest and is a
no-op once you are current, so future releases ship as additional versions you pick
up with another migration. See `ExShopifyApp.AccessToken.Migrations` for pinning a
specific `version`.

### 2. Define your store

```elixir
defmodule MyApp.ShopifyAccessTokens do
  use ExShopifyApp.AccessToken.Repo, repo: MyApp.Repo
end
```

This generates a module implementing `ExShopifyApp.AccessToken.Store` with
`fetch_token/1`, `put_token/2`, `valid_token/2`, and `refresh_token/2`.

### 3. Persist the token at install / re-auth

```elixir
{:ok, token} = ExShopifyApp.AccessToken.fetch(shop, session_token, expiring: true)
:ok = MyApp.ShopifyAccessTokens.put_token(shop.shopify_domain, token)
```

Don't consider the install complete until `put_token/2` returns `:ok`.

### 4. Get a usable token

`valid_token/2` is the safe primary API. It refreshes under a per-shop, cross-node lock
only when needed, and never returns a refreshed token until the new refresh token is
durably committed:

```elixir
case MyApp.ShopifyAccessTokens.valid_token(shop) do
  {:ok, token} -> # use token.access_token
  {:error, :reauthorization_required} -> # send the merchant back through OAuth
  {:error, reason} -> # operational error; retry / escalate
end
```

| State | Behaviour |
| --- | --- |
| Fresh token | Returned as-is — no lock, no HTTP call |
| Stale token | Locked refresh; on failure returns `{:error, reason}` (or the old token with `stale_while_error: true`) |
| Hard-expired token | Blocking locked refresh |
| Refresh token expired | `{:error, :reauthorization_required}` |
| No stored token | `{:error, :no_token}` |

### 5. Keep dormant shops alive (optional)

On-demand refreshing only fires when a token is used. A shop with no API activity
can silently cross the 90-day refresh-token expiry, after which only the merchant
relaunching the app restores access. Add the heartbeat process to your
supervision tree to rotate chains before they reach the cliff:

```elixir
{ExShopifyApp.AccessToken.Heartbeat,
 store: MyApp.ShopifyAccessTokens, repo: MyApp.Repo}
```

It scans every `:interval` (default 6h) for chains whose refresh token expires
within `:window` (default 7 days) and refreshes them through the store's lock —
safe to run on every node. Lifetime (non-expiring) rows are never touched.

## Safety guarantees

The store provides **at-least-once persistence attempt after a refresh response**, not
absolute never-loss. Refresh runs inside `Repo.transaction/2` holding a
`SELECT ... FOR UPDATE` row lock for the whole decision: it re-reads the row under the
lock, calls Shopify only if a refresh is still required, and synchronously persists the
new token before committing. The lock serializes refreshes across all processes and
nodes sharing the database.

The unavoidable residual risk is a VM/host crash after Shopify responds but before the
commit — Shopify and your database cannot share a transaction. Failures of the write
*after* a successful Shopify refresh surface as the distinct, critical
`{:error, {:token_persistence_failed_after_refresh, reason}}` and emit telemetry plus an
`error` log (token values redacted).

### Error taxonomy

- `{:error, :no_token}`
- `{:error, :reauthorization_required}`
- `{:error, {:refresh_failed, reason}}` (retryable)
- `{:error, {:token_persistence_failed_after_refresh, reason}}` (critical)
- `{:error, {:lock_timeout, reason}}`
- `{:error, {:refresh_crashed, reason}}`

### Telemetry

- `[:ex_shopify_app, :access_token, :refresh, :start | :stop | :exception]`
- `[:ex_shopify_app, :access_token, :refresh, :persistence_failed]`
- `[:ex_shopify_app, :access_token, :refresh, :stale_while_error]`

Metadata carries `:shopify_domain`, `:refresh_generation`, and a `:result`
classification — never token values.

## Docs

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and
published on [HexDocs](https://hexdocs.pm/ex_shopify_app).
