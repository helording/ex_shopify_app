import Config

# Keep test output readable: skip Ecto's per-query debug logging.
config :logger, level: :warning

# Route all Tesla calls through the Mox-backed adapter in the test env. The mock is
# defined in test/test_helper.exs; tests set expectations on its `call/2` callback.
config :tesla, adapter: ExShopifyApp.MockTeslaAdapter

# --- Ecto test repo --------------------------------------------------------
#
# Tests run inside the SQL sandbox: each test is wrapped in a transaction that is
# rolled back on completion, so no explicit table cleanup is needed.
config :ex_shopify_app, ExShopifyApp.TestRepo,
  url: "ecto://postgres:postgres@127.0.0.1:5432/ex_shopify_app_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Credentials read by ExShopifyApp.api_key/0 and api_secret/0.
config :ex_shopify_app,
  api_key: "test-api-key",
  api_secret: "test-api-secret"
