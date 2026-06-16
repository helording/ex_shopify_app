defmodule ExShopifyApp.Factory do
  @moduledoc """
  ex_machina factories + fixtures for Shopify access tokens.

  Factories build `Token` structs directly from absolute timestamps — never via
  `Token.from_response/2` or any other business logic — so fixtures stay independent
  of the code under test. `insert/2` writes through `ExShopifyApp.TestRepo`; use it to
  set up precondition rows. Tests that exercise `Store.put_token/2` itself should pass a
  built struct (`build(:token, ...)`) to `put_token` rather than `insert`.
  """

  use ExMachina.Ecto, repo: ExShopifyApp.TestRepo

  alias ExShopifyApp.AccessToken.Token

  @day 24 * 60 * 60

  @doc """
  A fresh, expiring offline token.

  Pass `:issued` (a `DateTime`) to shift the token into the past so the derived
  `expires_at` / `refresh_token_expires_at` land where a given state needs them.
  `:expires_in` and `:refresh_token_expires_in` override the lifetimes used to derive
  those timestamps. Any other attribute is merged onto the struct verbatim.
  """
  def token_factory(attrs) do
    issued = Map.get(attrs, :issued, DateTime.utc_now(:second))
    expires_in = Map.get(attrs, :expires_in, 3600)
    rt_expires_in = Map.get(attrs, :refresh_token_expires_in, 90 * @day)

    %Token{
      shopify_domain: sequence(:shopify_domain, &"shop-#{&1}.myshopify.com"),
      access_token: "shpat_old",
      refresh_token: "shprt_old",
      scope: "read_orders",
      expires_in: expires_in,
      expires_at: DateTime.add(issued, expires_in, :second),
      refresh_token_expires_in: rt_expires_in,
      refresh_token_expires_at: DateTime.add(issued, rt_expires_in, :second),
      refresh_generation: 0
    }
    |> merge_attributes(Map.drop(attrs, [:issued, :expires_in, :refresh_token_expires_in]))
    |> evaluate_lazy_attributes()
  end

  @doc "A lifetime (non-expiring) token: every expiry field stays `nil`."
  def lifetime_token_factory do
    %Token{
      shopify_domain: sequence(:shopify_domain, &"shop-#{&1}.myshopify.com"),
      access_token: "shpat_lifetime",
      scope: "read_orders",
      refresh_generation: 0
    }
  end

  @doc "An access token that has hard-expired (2h into a 1h lifetime)."
  def expired_token_factory(attrs) do
    build(:token, Map.put(attrs, :issued, hours_ago(2)))
  end

  @doc """
  An access token inside the proactive soft window (3300s into a 3600s lifetime),
  still valid but nearing expiry.
  """
  def stale_token_factory(attrs) do
    build(
      :token,
      Map.put(attrs, :issued, DateTime.add(DateTime.utc_now(:second), -3300, :second))
    )
  end

  @doc """
  A string-keyed token-exchange/refresh response body for the Tesla adapter mock.

  `overrides` is a string-keyed map merged over the defaults.
  """
  def token_response(overrides \\ %{}) do
    Map.merge(
      %{
        "access_token" => "shpat_new",
        "scope" => "read_orders",
        "expires_in" => 3600,
        "refresh_token" => "shprt_new",
        "refresh_token_expires_in" => 90 * @day
      },
      overrides
    )
  end

  defp hours_ago(h), do: DateTime.add(DateTime.utc_now(:second), -h * 3600, :second)
end
