defmodule ExShopifyApp.AccessTokenTest do
  use ExUnit.Case, async: true

  import Mox
  import ExShopifyApp.Factory, only: [token_response: 1]
  import ExShopifyApp.TestHelpers, only: [json_response: 2]

  alias ExShopifyApp.AccessToken
  alias ExShopifyApp.AccessToken.Token
  alias ExShopifyApp.MockTeslaAdapter

  # Each test runs in its own process and drives the adapter directly (no spawning), so
  # Mox's default private mode is enough; verify_on_exit! asserts every expectation ran.
  setup :verify_on_exit!

  @shop %{shopify_domain: "shop.myshopify.com"}

  @expiring_body token_response(%{
                   "access_token" => "shpat_123",
                   "scope" => "write_orders",
                   "refresh_token" => "shprt_456"
                 })

  describe "fetch/3" do
    test "requests an expiring offline token by default and parses the response" do
      expect(MockTeslaAdapter, :call, fn %{method: :post, url: url, body: body}, _opts ->
        assert url == "https://shop.myshopify.com/admin/oauth/access_token"
        params = JSON.decode!(body)
        assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange"

        assert params["requested_token_type"] ==
                 "urn:shopify:params:oauth:token-type:offline-access-token"

        assert params["subject_token"] == "session-token"
        assert params["expiring"] == "1"
        {:ok, json_response(@expiring_body, status: 200)}
      end)

      assert {:ok, %Token{} = token} = AccessToken.fetch(@shop, "session-token")
      assert token.access_token == "shpat_123"
      assert token.refresh_token == "shprt_456"
      assert token.shopify_domain == "shop.myshopify.com"
      assert %DateTime{} = token.expires_at
    end

    test "omits the expiring param when expiring: false" do
      expect(MockTeslaAdapter, :call, fn %{method: :post, body: body}, _opts ->
        refute Map.has_key?(JSON.decode!(body), "expiring")

        {:ok,
         json_response(%{"access_token" => "shpat_x", "scope" => "read_orders"}, status: 200)}
      end)

      assert {:ok, %Token{expires_at: nil}} =
               AccessToken.fetch(@shop, "session-token", expiring: false)
    end

    test "requests an online token when type: :online" do
      expect(MockTeslaAdapter, :call, fn %{method: :post, body: body}, _opts ->
        params = JSON.decode!(body)

        assert params["requested_token_type"] ==
                 "urn:shopify:params:oauth:token-type:online-access-token"

        {:ok, json_response(@expiring_body, status: 200)}
      end)

      assert {:ok, %Token{}} = AccessToken.fetch(@shop, "session-token", type: :online)
    end

    test "non-200 returns {:error, env}" do
      expect(MockTeslaAdapter, :call, fn _env, _opts ->
        {:ok, json_response(%{"error" => "invalid_subject_token"}, status: 400)}
      end)

      assert {:error, %Tesla.Env{status: 400}} = AccessToken.fetch(@shop, "session-token")
    end
  end

  describe "refresh/2" do
    test "posts a refresh_token grant and returns a new token" do
      expect(MockTeslaAdapter, :call, fn %{method: :post, body: body}, _opts ->
        params = JSON.decode!(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "shprt_old"
        assert params["client_id"] == "test-api-key"
        {:ok, json_response(%{@expiring_body | "refresh_token" => "shprt_new"}, status: 200)}
      end)

      assert {:ok, %Token{} = token} = AccessToken.refresh(@shop, "shprt_old")
      assert token.refresh_token == "shprt_new"
      assert token.shopify_domain == "shop.myshopify.com"
    end

    test "non-200 returns {:error, env}" do
      expect(MockTeslaAdapter, :call, fn _env, _opts ->
        {:ok, json_response(%{"error" => "invalid_grant"}, status: 400)}
      end)

      assert {:error, %Tesla.Env{status: 400}} = AccessToken.refresh(@shop, "shprt_old")
    end
  end
end
