defmodule ExShopifyApp.AccessToken do
  @moduledoc """
  Access token management.

  Exchanges session tokens for offline/online access tokens and refreshes expiring
  offline access tokens. Returns `ExShopifyApp.AccessToken.Token` structs carrying the
  full expiry metadata.

  Docs:
  - <https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/token-exchange#example>
  - <https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/offline-access-tokens>
  """

  import ExShopifyApp, only: [api_key: 0, api_secret: 0]

  alias ExShopifyApp.AccessToken.Token

  @typep shop :: %{shopify_domain: String.t()}

  @doc """
  Exchange a session token for an access token.

  By default an **expiring** offline token is requested (Shopify is replacing lifetime
  tokens with expiring ones). Pass `expiring: false` to request a legacy lifetime token.

  ## Options
    * `:type` - `:offline` (default) or `:online`
    * `:expiring` - request an expiring token (default `true`)
  """
  @spec fetch(shop(), String.t(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def fetch(shop, session_token, opts \\ []) when is_binary(session_token) do
    type = Keyword.get(opts, :type, :offline)
    expiring = Keyword.get(opts, :expiring, true)

    if type not in [:offline, :online] do
      raise ArgumentError, ":type must be :offline or :online, got: #{inspect(type)}"
    end

    body = %{
      client_id: api_key(),
      client_secret: api_secret(),
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      subject_token: session_token,
      subject_token_type: "urn:ietf:params:oauth:token-type:id_token",
      requested_token_type: "urn:shopify:params:oauth:token-type:#{to_string(type)}-access-token"
    }

    body =
      if expiring,
        do: Map.put(body, :expiring, "1"),
        else: body

    shop
    |> client()
    |> Tesla.post("/oauth/access_token", body)
    |> unwrap_token_response(fn resp ->
      {:ok, Token.from_response(resp.body, Map.get(shop, :shopify_domain))}
    end)
  end

  @doc """
  Refresh an expiring offline access token using its refresh token.

  Both the access token and the refresh token are regenerated; the previous refresh
  token is invalidated, so the returned token's `refresh_token` **must** be persisted.

  This function only performs the HTTP exchange and decides nothing about persistence
  or locking. Concurrent refreshes for the same shop would invalidate each other — use
  `ExShopifyApp.AccessToken.Repo` (or another `ExShopifyApp.AccessToken.Store`) to
  serialize and durably persist them.
  """
  @spec refresh(shop(), String.t()) :: {:ok, Token.t()} | {:error, term()}
  def refresh(shop, refresh_token) when is_binary(refresh_token) do
    body = %{
      client_id: api_key(),
      client_secret: api_secret(),
      grant_type: "refresh_token",
      refresh_token: refresh_token
    }

    shop
    |> client()
    |> Tesla.post("/oauth/access_token", body)
    |> unwrap_token_response(fn resp ->
      {:ok, Token.from_response(resp.body, Map.get(shop, :shopify_domain))}
    end)
  end

  @doc """
  Migrate a non-expiring (lifetime) offline access token to an expiring one.

  Shopify is replacing lifetime offline tokens with expiring ones. This performs a
  token exchange that takes the existing non-expiring offline token as the subject and
  returns an expiring offline token plus its refresh token. The returned token's
  `refresh_token` **must** be persisted so it can later be refreshed via `refresh/2`.

  Docs:
  - <https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/offline-access-tokens#migrate-to-expiring-offline-access-tokens>
  """
  @spec migrate(shop(), String.t()) :: {:ok, Token.t()} | {:error, term()}
  def migrate(shop, offline_token) when is_binary(offline_token) do
    body = %{
      client_id: api_key(),
      client_secret: api_secret(),
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      subject_token: offline_token,
      subject_token_type: "urn:shopify:params:oauth:token-type:offline-access-token",
      requested_token_type: "urn:shopify:params:oauth:token-type:offline-access-token",
      expiring: "1"
    }

    shop
    |> client()
    |> Tesla.post("/oauth/access_token", body)
    |> unwrap_token_response(fn resp ->
      {:ok, Token.from_response(resp.body, Map.get(shop, :shopify_domain))}
    end)
  end

  @spec client(shop()) :: Tesla.Client.t()
  def client(%{shopify_domain: shopify_domain} = _shop) do
    host = String.trim_leading(shopify_domain, "https://")

    Tesla.client(
      [
        {Tesla.Middleware.BaseUrl, "https://#{host}/admin"},
        {Tesla.Middleware.JSON, engine: JSON}
      ],
      Application.get_env(:tesla, :adapter, Tesla.Adapter.Mint)
    )
  end

  @spec unwrap_token_response(Tesla.Env.result(), (Tesla.Env.t() -> {:ok, Token.t()})) ::
          {:ok, Token.t()} | {:error, term()}
  defp unwrap_token_response({:ok, %Tesla.Env{status: 200} = resp}, fun)
       when is_function(fun, 1) do
    fun.(resp)
  end

  defp unwrap_token_response({:ok, %Tesla.Env{} = resp}, _fun), do: {:error, resp}
  defp unwrap_token_response({:error, reason}, _fun), do: {:error, reason}
end
