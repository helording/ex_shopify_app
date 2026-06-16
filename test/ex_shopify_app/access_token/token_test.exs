defmodule ExShopifyApp.AccessToken.TokenTest do
  use ExUnit.Case, async: true

  alias ExShopifyApp.AccessToken.Token

  @now ~U[2026-05-21 12:00:00Z]
  @now_usec ~U[2026-05-21 12:00:00.123456Z]

  # Token lifetimes mirror Shopify's grant durations: a 1h access token and a
  # 90-day refresh token. :timer.* returns milliseconds, so convert to the
  # seconds that Shopify's expires_in and DateTime.add/3 use.
  @access_token_ttl div(:timer.hours(1), 1000)
  @refresh_token_ttl div(:timer.hours(90 * 24), 1000)
  # Comfortably past every expiry — used to probe that lifetime tokens never expire.
  @far_future @refresh_token_ttl * 2

  @expiring %{
    "access_token" => "shpat_123",
    "scope" => "write_orders,read_customers",
    "expires_in" => @access_token_ttl,
    "refresh_token" => "shprt_456",
    "refresh_token_expires_in" => @refresh_token_ttl
  }

  describe "from_response/2" do
    test "computes absolute expiries from durations" do
      before = DateTime.utc_now(:second)
      token = Token.from_response(@expiring, "shop.myshopify.com")
      after_call = DateTime.utc_now(:second)

      assert token.access_token == "shpat_123"
      assert token.scope == "write_orders,read_customers"
      assert token.refresh_token == "shprt_456"
      assert token.shopify_domain == "shop.myshopify.com"

      assert DateTime.compare(token.expires_at, DateTime.add(before, @access_token_ttl, :second)) !=
               :lt

      assert DateTime.compare(
               token.expires_at,
               DateTime.add(after_call, @access_token_ttl, :second)
             ) != :gt

      assert DateTime.compare(
               token.refresh_token_expires_at,
               DateTime.add(before, @refresh_token_ttl, :second)
             ) != :lt

      assert DateTime.compare(
               token.refresh_token_expires_at,
               DateTime.add(after_call, @refresh_token_ttl, :second)
             ) != :gt
    end

    test "sets expiry timestamps at second precision" do
      token = Token.from_response(@expiring, "shop.myshopify.com")

      assert token.expires_at.microsecond == {0, 0}
      assert token.refresh_token_expires_at.microsecond == {0, 0}
    end

    test "lifetime token (no expires_in) leaves expiry fields nil" do
      token =
        Token.from_response(%{"access_token" => "shpat_x", "scope" => "read_orders"}, "s")

      assert token.expires_at == nil
      assert token.refresh_token_expires_at == nil
      assert token.refresh_token == nil
    end
  end

  describe "expired?/3" do
    setup do
      %{token: expiring_token()}
    end

    test "false well before expiry", %{token: token} do
      refute Token.expired?(token, @now)
    end

    test "true past expiry", %{token: token} do
      after_expiry = DateTime.add(token.expires_at, 1, :second)
      assert Token.expired?(token, after_expiry)
    end

    test "respects the skew window", %{token: token} do
      # 30s before real expiry, with a 60s skew => already considered expired.
      almost = DateTime.add(token.expires_at, -30, :second)
      assert Token.expired?(token, almost, 60)
      refute Token.expired?(token, almost, 10)
    end

    test "lifetime token is never expired" do
      token = lifetime_token()
      refute Token.expired?(token, DateTime.add(@now, @far_future, :second))
    end
  end

  describe "stale?/3" do
    setup do
      %{token: expiring_token()}
    end

    test "false early in the token's life", %{token: token} do
      refute Token.stale?(token, @now, jitter: 0)
    end

    test "true once inside the soft window", %{token: token} do
      # 10 minutes before expiry: < 25% of a 3600s lifetime remaining.
      inside = DateTime.add(token.expires_at, -600, :second)
      assert Token.stale?(token, inside, jitter: 0)
    end

    test "jitter is deterministic per shop" do
      a = expiring_token("shop-a.myshopify.com")
      b = expiring_token("shop-a.myshopify.com")
      c = expiring_token("shop-b.myshopify.com")

      probe = fn token -> Token.stale?(token, DateTime.add(token.expires_at, -905, :second)) end

      # Same domain => same decision; jitter is a stable function of the domain.
      assert probe.(a) == probe.(b)
      # (c may differ; we only assert determinism within a domain.)
      assert is_boolean(probe.(c))
    end

    test "lifetime token is never stale" do
      token = lifetime_token()
      refute Token.stale?(token, DateTime.add(@now, @far_future, :second))
    end
  end

  describe "changeset/2" do
    @valid_attrs %{
      shopify_domain: "shop.myshopify.com",
      access_token: "shpat_123",
      refresh_token: "shprt_456",
      scope: "write_orders",
      expires_in: @access_token_ttl,
      expires_at: DateTime.add(@now, @access_token_ttl, :second),
      refresh_token_expires_in: @refresh_token_ttl,
      refresh_token_expires_at: DateTime.add(@now, @refresh_token_ttl, :second)
    }

    test "valid for a complete expiring token" do
      assert Token.changeset(%Token{}, @valid_attrs).valid?
    end

    test "truncates expiry changes to match utc_datetime precision" do
      changeset =
        Token.changeset(%Token{}, %{
          @valid_attrs
          | expires_at: DateTime.add(@now_usec, @access_token_ttl, :second),
            refresh_token_expires_at: DateTime.add(@now_usec, @refresh_token_ttl, :second)
        })

      assert Ecto.Changeset.get_field(changeset, :expires_at) ==
               @now_usec |> DateTime.add(@access_token_ttl, :second) |> DateTime.truncate(:second)

      assert Ecto.Changeset.get_field(changeset, :refresh_token_expires_at) ==
               @now_usec
               |> DateTime.add(@refresh_token_ttl, :second)
               |> DateTime.truncate(:second)
    end

    test "requires shopify_domain and access_token" do
      changeset = Token.changeset(%Token{}, %{})
      refute changeset.valid?
      assert %{shopify_domain: ["can't be blank"]} = errors(changeset)
      assert %{access_token: ["can't be blank"]} = errors(changeset)
    end

    test "an expiring token requires refresh_token and the expiry timestamps" do
      attrs = Map.drop(@valid_attrs, [:refresh_token, :refresh_token_expires_at])
      changeset = Token.changeset(%Token{}, attrs)
      refute changeset.valid?
      assert Map.has_key?(errors(changeset), :refresh_token)
      assert Map.has_key?(errors(changeset), :refresh_token_expires_at)
    end

    test "a lifetime token needs only shopify_domain and access_token" do
      changeset =
        Token.changeset(%Token{}, %{shopify_domain: "s.myshopify.com", access_token: "x"})

      assert changeset.valid?
    end

    test "rejects negative durations" do
      changeset = Token.changeset(%Token{}, %{@valid_attrs | expires_in: -1})
      refute changeset.valid?
      assert Map.has_key?(errors(changeset), :expires_in)
    end

    test "normalizes shopify_domain by stripping a leading https://" do
      changeset =
        Token.changeset(%Token{}, %{@valid_attrs | shopify_domain: "https://shop.myshopify.com"})

      assert Ecto.Changeset.get_field(changeset, :shopify_domain) == "shop.myshopify.com"
    end

    defp errors(changeset) do
      Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    end
  end

  describe "prepare_refresh_changes/2" do
    test "copies refreshed values, stamps metadata, and increments the generation" do
      existing =
        expiring_token()
        |> Map.put(:refresh_generation, 2)

      refreshed =
        expiring_token()
        |> Map.put(:refresh_token, "shprt_new")

      before = DateTime.utc_now()
      changeset = Token.prepare_refresh_changes(refreshed, existing)
      after_call = DateTime.utc_now()

      last_refreshed_at = Ecto.Changeset.get_change(changeset, :last_refreshed_at)

      assert Ecto.Changeset.get_change(changeset, :refresh_token) == "shprt_new"
      assert DateTime.compare(last_refreshed_at, before) != :lt
      assert DateTime.compare(last_refreshed_at, after_call) != :gt
      # optimistic_lock filters on the observed generation (2) and increments it on the
      # repo write; the end-to-end bump to the next generation is covered by the store's
      # hard-expired refresh test.
      assert changeset.filters[:refresh_generation] == 2
    end
  end

  describe "refresh_token_expired?/2" do
    setup do
      %{token: expiring_token()}
    end

    test "false before the 90-day window passes", %{token: token} do
      refute Token.refresh_token_expired?(token, @now)
    end

    test "true after the window passes", %{token: token} do
      after_window = DateTime.add(token.refresh_token_expires_at, 1, :second)
      assert Token.refresh_token_expired?(token, after_window)
    end

    test "lifetime token's refresh never expires" do
      token = lifetime_token()
      refute Token.refresh_token_expired?(token, DateTime.add(@now, @far_future, :second))
    end
  end

  describe "refresh_token_expiring?/3" do
    test "false for lifetime tokens regardless of window" do
      refute Token.refresh_token_expiring?(lifetime_token(), @now, @refresh_token_ttl)
    end

    test "false when no window is given" do
      refute Token.refresh_token_expiring?(expiring_token(), @now, nil)
    end

    test "true only once the refresh token expires inside the window" do
      token = expiring_token()
      seconds_left = DateTime.diff(token.refresh_token_expires_at, @now, :second)

      assert Token.refresh_token_expiring?(token, @now, seconds_left + 60)
      refute Token.refresh_token_expiring?(token, @now, seconds_left - 60)
    end
  end

  defp expiring_token(shopify_domain \\ "shop.myshopify.com") do
    %Token{
      shopify_domain: shopify_domain,
      access_token: "shpat_123",
      refresh_token: "shprt_456",
      scope: "write_orders,read_customers",
      expires_in: @access_token_ttl,
      expires_at: DateTime.add(@now, @access_token_ttl, :second),
      refresh_token_expires_in: @refresh_token_ttl,
      refresh_token_expires_at: DateTime.add(@now, @refresh_token_ttl, :second),
      refresh_generation: 0
    }
  end

  defp lifetime_token do
    %Token{shopify_domain: "s", access_token: "x"}
  end
end
