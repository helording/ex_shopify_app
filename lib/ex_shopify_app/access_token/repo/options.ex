defmodule ExShopifyApp.AccessToken.Repo.Options do
  @moduledoc """
  Reads call options for `ExShopifyApp.AccessToken.Repo` and applies their defaults.

  See the `ExShopifyApp.AccessToken.Repo` "Options" section for the full list and
  semantics.
  """

  @doc "Hard-expiry skew in seconds (default `60`)."
  def skew(opts), do: Keyword.get(opts, :skew, 60)

  @doc "Soft-window opts passed to `ExShopifyApp.AccessToken.Token.stale?/3` (default `[]`)."
  def soft_window(opts), do: Keyword.get(opts, :soft_window, [])

  @doc "Whether to serve a still-valid old token when a refresh fails (`:stale_while_error`, default `false`)."
  def stale_while_error?(opts), do: Keyword.get(opts, :stale_while_error, false)

  @doc "Keep-alive window in seconds before refresh-token expiry (`:refresh_token_window`, default `nil` — disabled)."
  def refresh_token_window(opts), do: Keyword.get(opts, :refresh_token_window, nil)

  @doc "`Repo.transaction/2` options derived from `:timeout` (empty list when unset)."
  def transaction_opts(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> []
      timeout -> [timeout: timeout]
    end
  end

  @doc """
  Invoke `fun` with the `:lock_timeout` in milliseconds when one is configured.

  Returns `:ok` and skips `fun` when no `:lock_timeout` is set. Keeps the actual
  `SET LOCAL lock_timeout` query in the caller so this module stays repo-agnostic.
  """
  def with_lock_timeout(opts, fun) when is_function(fun, 1) do
    case Keyword.get(opts, :lock_timeout) do
      nil -> :ok
      ms when is_integer(ms) and ms >= 0 -> fun.(ms)
    end
  end
end
