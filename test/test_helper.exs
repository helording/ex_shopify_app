ExUnit.start(capture_log: true)

# Tesla HTTP calls are routed through this Mox-backed adapter in the test env (see
# config/test.exs). The adapter implements the `Tesla.Adapter` behaviour, so tests set
# expectations on its `call/2` callback both to stub responses and to assert call counts.
Mox.defmock(ExShopifyApp.MockTeslaAdapter, for: Tesla.Adapter)

{:ok, _} = ExShopifyApp.TestRepo.start_link()

# Recreate the schema from scratch on every run so the table always matches the
# documented migration contract, regardless of prior state.
Ecto.Adapters.SQL.query!(
  ExShopifyApp.TestRepo,
  "DROP TABLE IF EXISTS shopify_access_tokens, schema_migrations CASCADE"
)

Ecto.Migrator.run(
  ExShopifyApp.TestRepo,
  [{0, ExShopifyApp.TestRepo.Migrations.CreateShopifyAccessTokens}],
  :up,
  all: true
)

Ecto.Adapters.SQL.Sandbox.mode(ExShopifyApp.TestRepo, :manual)

defmodule ExShopifyApp.TestHelpers do
  @moduledoc """
  Test helpers. We build responses with the built-in `JSON` engine the client itself
  uses (rather than a Jason-dependent helper), since the library intentionally does not
  depend on Jason.
  """

  @doc """
  Build a `Tesla.Env` JSON response.

  Returned from the `ExShopifyApp.MockTeslaAdapter` `call/2` expectation wrapped in an
  `{:ok, env}` tuple, as the `Tesla.Adapter` behaviour requires.
  """
  def json_response(body, opts \\ []) do
    %Tesla.Env{
      status: Keyword.get(opts, :status, 200),
      body: JSON.encode!(body),
      headers: [{"content-type", "application/json"}]
    }
  end

  @doc "Fetch the persisted token for a shop, asserting one exists."
  def stored(domain) do
    {:ok, token} = ExShopifyApp.TestStore.fetch_token(domain)
    token
  end
end
