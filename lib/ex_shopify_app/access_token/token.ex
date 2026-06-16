defmodule ExShopifyApp.AccessToken.Token do
  @moduledoc """
  The canonical persisted representation of a Shopify offline access token.

  This is an Ecto schema keyed by `shopify_domain`: there is exactly one offline
  token chain per shop/app installation. It captures the full response from an
  expiring token exchange or refresh, the absolute timestamps at which the access
  token and refresh token expire, and operational refresh metadata.

  Lifetime (non-expiring) tokens leave `:expires_at` and `:refresh_token_expires_at`
  as `nil`; such tokens are never considered expired or stale.

  The struct redacts `:access_token` and `:refresh_token` from `inspect/2` output so
  token values never leak into logs.

  Docs: <https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/offline-access-tokens>
  """

  use Ecto.Schema

  import Ecto.Changeset

  @typedoc "An offline access token row with its expiry and refresh metadata."
  @type t :: %__MODULE__{
          shopify_domain: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          scope: String.t() | nil,
          expires_in: non_neg_integer() | nil,
          expires_at: DateTime.t() | nil,
          refresh_token_expires_in: non_neg_integer() | nil,
          refresh_token_expires_at: DateTime.t() | nil,
          last_refreshed_at: DateTime.t() | nil,
          last_refresh_error: String.t() | nil,
          refresh_generation: non_neg_integer()
        }

  @derive {Inspect, except: [:access_token, :refresh_token]}
  @primary_key {:shopify_domain, :string, autogenerate: false}
  schema "shopify_access_tokens" do
    field(:access_token, :string)
    field(:refresh_token, :string)
    field(:scope, :string)

    field(:expires_in, :integer)
    field(:expires_at, :utc_datetime)
    field(:refresh_token_expires_in, :integer)
    field(:refresh_token_expires_at, :utc_datetime)

    field(:last_refreshed_at, :utc_datetime_usec)
    field(:last_refresh_error, :string)
    field(:refresh_generation, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(
    shopify_domain access_token refresh_token scope
    expires_in expires_at refresh_token_expires_in refresh_token_expires_at
    last_refreshed_at last_refresh_error refresh_generation
  )a

  # Default hard-expiry skew (seconds): treat a token as expired this many seconds
  # before its real `expires_at` so we never use one about to expire mid-request.
  @default_skew 60

  # Default soft-window threshold: refresh proactively once remaining lifetime drops
  # below this fraction of the original `expires_in`.
  @default_soft_fraction 0.25

  # Maximum jitter (seconds) added to the soft window, spread deterministically per
  # shop so tokens issued together don't all refresh on the same tick.
  @default_jitter 30

  @doc "Returns the fields accepted by `changeset/2`."
  @spec castable() :: [atom()]
  def castable, do: @castable

  @doc "Returns the fields replaced during an upsert conflict."
  @spec replaceable() :: [atom()]
  def replaceable, do: (@castable -- [:shopify_domain]) ++ [:updated_at]

  @doc """
  Builds a token struct from a decoded token-exchange/refresh response body.

  Computes absolute expiry timestamps from the `expires_in`/`refresh_token_expires_in`
  durations relative to the current time. Accepts string-keyed maps (as decoded from
  JSON). The result is a transient struct — persist it through a
  `ExShopifyApp.AccessToken.Store` before relying on it.
  """
  @spec from_response(map(), String.t() | nil) :: t()
  def from_response(body, shopify_domain \\ nil) when is_map(body) do
    expires_in = body["expires_in"]
    refresh_token_expires_in = body["refresh_token_expires_in"]

    now = DateTime.utc_now(:second)

    %__MODULE__{
      shopify_domain: normalize_domain(shopify_domain),
      access_token: body["access_token"],
      scope: body["scope"],
      refresh_token: body["refresh_token"],
      expires_in: expires_in,
      refresh_token_expires_in: refresh_token_expires_in,
      expires_at: add_seconds(now, expires_in),
      refresh_token_expires_at: add_seconds(now, refresh_token_expires_in)
    }
  end

  @doc """
  Changeset for persisting a token (initial exchange / reauthorization upsert).

  Requires `shopify_domain` and `access_token`. For expiring tokens (any expiry field
  present) it additionally requires `refresh_token`, `expires_at`, and
  `refresh_token_expires_at`. Integer durations must be non-negative. The
  `shopify_domain` is normalized consistently with the HTTP client's host handling.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, castable())
    |> update_change(:shopify_domain, &normalize_domain/1)
    |> update_change(:expires_at, &truncate_to_seconds/1)
    |> update_change(:refresh_token_expires_at, &truncate_to_seconds/1)
    |> validate_required([:shopify_domain, :access_token])
    |> validate_required_for_expiring()
    |> validate_durations()
  end

  @doc """
  Builds the update changeset applied after a successful refresh.

  Copies the freshly issued values from `refreshed` onto the locked `existing` row,
  stamps `last_refreshed_at`, clears `last_refresh_error`, and uses
  `Ecto.Changeset.optimistic_lock/3` to increment `refresh_generation` (and guard
  against a concurrent writer). The `shopify_domain` is preserved.
  """
  @spec prepare_refresh_changes(t(), t()) :: Ecto.Changeset.t()
  def prepare_refresh_changes(%__MODULE__{} = refreshed, %__MODULE__{} = existing) do
    existing
    |> change(%{
      access_token: refreshed.access_token,
      refresh_token: refreshed.refresh_token,
      scope: refreshed.scope,
      expires_in: refreshed.expires_in,
      expires_at: truncate_to_seconds(refreshed.expires_at),
      refresh_token_expires_in: refreshed.refresh_token_expires_in,
      refresh_token_expires_at: truncate_to_seconds(refreshed.refresh_token_expires_at),
      last_refreshed_at: DateTime.utc_now(),
      last_refresh_error: nil
    })
    |> optimistic_lock(:refresh_generation)
  end

  @doc """
  Normalizes a shop domain the same way `ExShopifyApp.AccessToken.client/1` does:
  strips a leading `https://` so the stored key matches the host used for requests.
  """
  @spec normalize_domain(String.t() | nil) :: String.t() | nil
  def normalize_domain(nil), do: nil

  def normalize_domain(domain) when is_binary(domain) do
    String.trim_leading(domain, "https://")
  end

  @doc """
  Returns `true` when the access token has hard-expired (within `skew` seconds).

  A blocking refresh is required before the token can be used. Lifetime tokens
  (`expires_at == nil`) are never expired.
  """
  @spec expired?(t(), DateTime.t(), non_neg_integer()) :: boolean()
  def expired?(token, now \\ DateTime.utc_now(), skew \\ @default_skew)

  def expired?(%__MODULE__{expires_at: nil}, _now, _skew), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now, skew) do
    effective_expiry = DateTime.add(expires_at, -skew, :second)
    DateTime.compare(now, effective_expiry) != :lt
  end

  @doc """
  Returns `true` when the refresh token expires within `window` seconds of `now`.

  Drives heartbeat rotation: a dormant shop's access token may be fresh (or
  long-expired and untouched) while its refresh token silently approaches the
  90-day cliff after which only the merchant can restore access. Lifetime tokens
  and a `nil` window are never expiring.
  """
  @spec refresh_token_expiring?(t(), DateTime.t(), non_neg_integer() | nil) :: boolean()
  def refresh_token_expiring?(token, now \\ DateTime.utc_now(), window)

  def refresh_token_expiring?(%__MODULE__{refresh_token_expires_at: nil}, _now, _window),
    do: false

  def refresh_token_expiring?(%__MODULE__{}, _now, nil), do: false

  def refresh_token_expiring?(%__MODULE__{refresh_token_expires_at: expires_at}, now, window)
      when is_integer(window) and window >= 0 do
    DateTime.compare(now, DateTime.add(expires_at, -window, :second)) != :lt
  end

  @doc """
  Returns `true` when the access token is inside the proactive *soft* refresh window
  (still valid, but nearing expiry) — a stale-while-revalidate refresh should be
  triggered.

  The window opens once remaining lifetime drops below `:fraction` of the original
  `expires_in` (default `#{@default_soft_fraction}`), plus a deterministic per-shop
  jitter of up to `:jitter` seconds (default `#{@default_jitter}`) so co-issued tokens
  stagger their refreshes. Lifetime tokens are never stale.

  ## Options
    * `:fraction` - soft-window fraction of total lifetime (default `#{@default_soft_fraction}`)
    * `:jitter` - max jitter in seconds, spread per shop (default `#{@default_jitter}`)
  """
  @spec stale?(t(), DateTime.t(), keyword()) :: boolean()
  def stale?(token, now \\ DateTime.utc_now(), opts \\ [])

  def stale?(%__MODULE__{expires_at: nil}, _now, _opts), do: false

  def stale?(%__MODULE__{expires_in: nil}, _now, _opts), do: false

  def stale?(%__MODULE__{expires_at: expires_at, expires_in: expires_in} = token, now, opts) do
    fraction = Keyword.get(opts, :fraction, @default_soft_fraction)
    max_jitter = Keyword.get(opts, :jitter, @default_jitter)

    threshold = round(expires_in * fraction) + jitter(token, max_jitter)
    effective_expiry = DateTime.add(expires_at, -threshold, :second)
    DateTime.compare(now, effective_expiry) != :lt
  end

  @doc """
  Returns `true` when the refresh token has expired. Once this is true the merchant
  must re-launch the app to obtain a new token; refreshing is no longer possible.
  """
  @spec refresh_token_expired?(t(), DateTime.t()) :: boolean()
  def refresh_token_expired?(token, now \\ DateTime.utc_now())

  def refresh_token_expired?(%__MODULE__{refresh_token_expires_at: nil}, _now), do: false

  def refresh_token_expired?(%__MODULE__{refresh_token_expires_at: expires_at}, now) do
    DateTime.compare(now, expires_at) != :lt
  end

  # Require the full expiring-token field set whenever the token carries any expiry
  # data; lifetime tokens (no expiry fields) stay valid with just an access token.
  defp validate_required_for_expiring(changeset) do
    expiring? =
      Enum.any?(
        [:expires_in, :expires_at, :refresh_token_expires_in, :refresh_token_expires_at],
        &(not is_nil(get_field(changeset, &1)))
      )

    if expiring? do
      validate_required(changeset, [:refresh_token, :expires_at, :refresh_token_expires_at])
    else
      changeset
    end
  end

  defp validate_durations(changeset) do
    changeset
    |> validate_number(:expires_in, greater_than_or_equal_to: 0)
    |> validate_number(:refresh_token_expires_in, greater_than_or_equal_to: 0)
  end

  # Deterministic per-shop jitter in [0, max_jitter]. Same domain always maps to the
  # same value, so a shop's refresh timing is stable but offset from its neighbours.
  defp jitter(_token, max_jitter) when max_jitter <= 0, do: 0

  defp jitter(%__MODULE__{shopify_domain: domain}, max_jitter) do
    :erlang.phash2(domain, max_jitter + 1)
  end

  defp truncate_to_seconds(nil), do: nil

  defp truncate_to_seconds(%DateTime{} = datetime) do
    DateTime.truncate(datetime, :second)
  end

  defp add_seconds(_datetime, nil), do: nil

  defp add_seconds(datetime, seconds) do
    DateTime.add(datetime, seconds, :second)
  end
end
