defmodule ExShopifyApp.AccessToken.PersistenceFailure do
  @moduledoc """
  Carries the token that Shopify successfully issued but that could not be durably
  written, so a caller can retry the persistence instead of losing the token.

  Returned inside `{:error, {:token_persistence_failed_after_refresh, %PersistenceFailure{}}}`
  by `ExShopifyApp.AccessToken.Repo.refresh_token/3` and `migrate_token/3` when the
  Shopify exchange succeeded but the durable write inside the surrounding transaction
  failed (e.g. a transient connection drop or timeout).

  By the time this surfaces, Shopify has already invalidated the prior token, so
  re-running the exchange will fail — the only recovery is to persist `token`
  (for example via the store's `put_token/2`). `reason` is the original write error
  for logging/classification.
  """

  alias ExShopifyApp.AccessToken.Token

  @typedoc "The exchanged-but-unpersisted token plus the underlying write error."
  @type t :: %__MODULE__{reason: term(), token: Token.t()}

  @enforce_keys [:reason, :token]
  defstruct [:reason, :token]
end
