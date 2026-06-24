defmodule ExShopifyApp.AccessToken.Telemetry do
  @moduledoc """
  Telemetry emission for offline access-token refreshes.

  All events share the `[:ex_shopify_app, :access_token, :refresh]` prefix:

    * `[..., :start | :stop | :exception]` — the refresh span.
    * `[..., :persistence_failed]` — Shopify returned a new token but the durable write
      failed (also logged at `error`).
    * `[..., :stale_while_error]` — a refresh failed but the still-valid old token was
      served.
    * `[..., :reauthorization_required]` — the chain can no longer be refreshed and the
      merchant must relaunch the app to reauthorize. Emitted whenever a call resolves to
      `:reauthorization_required`, regardless of the path that produced it (an already
      expired refresh token short-circuited before any HTTP call, or Shopify rejected the
      refresh with `invalid_grant`).

  Metadata carries `:shopify_domain`, `:refresh_generation`, and a `:result`
  classification — never token values.
  """

  require Logger

  @event [:ex_shopify_app, :access_token, :refresh]

  @doc """
  Emit the refresh `:start` event and return the monotonic start time to pair with
  `refresh_stop/3` or `refresh_exception/4`.
  """
  def refresh_start(meta) do
    start_time = System.monotonic_time()
    :telemetry.execute(@event ++ [:start], %{system_time: System.system_time()}, meta)
    start_time
  end

  @doc "Emit the refresh `:stop` event with the elapsed duration and classified result."
  def refresh_stop(start_time, meta, result) do
    classification = classify(result)

    :telemetry.execute(
      @event ++ [:stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(meta, :result, classification)
    )

    maybe_reauthorization_required(meta, classification)
  end

  @doc "Emit the refresh `:exception` event for a crash in the refresh path."
  def refresh_exception(start_time, meta, exception, stacktrace) do
    :telemetry.execute(
      @event ++ [:exception],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(meta, %{
        kind: :error,
        reason: exception,
        stacktrace: stacktrace
      })
    )
  end

  @doc "Emit the `:persistence_failed` event and log the critical loss-of-token warning."
  def persistence_failed(domain, token) do
    :telemetry.execute(
      @event ++ [:persistence_failed],
      %{system_time: System.system_time()},
      %{
        shopify_domain: domain,
        refresh_generation: token.refresh_generation
      }
    )

    Logger.error(
      "ex_shopify_app: durable persistence FAILED after a successful Shopify refresh " <>
        "for #{domain} (token values redacted). The new refresh token may be lost — " <>
        "the shop may need to reauthorize."
    )
  end

  @doc "Emit the `:stale_while_error` event when the old token is served after a failed refresh."
  def stale_while_error(token, reason) do
    :telemetry.execute(
      @event ++ [:stale_while_error],
      %{system_time: System.system_time()},
      %{
        shopify_domain: token.shopify_domain,
        refresh_generation: token.refresh_generation,
        result: classify({:error, reason})
      }
    )
  end

  @doc """
  Emit the `:reauthorization_required` event for `domain`.

  Call this on every path that resolves to `:reauthorization_required` so the merchant
  re-auth signal surfaces regardless of whether an HTTP refresh was attempted.
  """
  def reauthorization_required(domain) do
    :telemetry.execute(
      @event ++ [:reauthorization_required],
      %{system_time: System.system_time()},
      %{shopify_domain: domain}
    )
  end

  defp maybe_reauthorization_required(%{shopify_domain: domain}, :reauthorization_required) do
    reauthorization_required(domain)
  end

  defp maybe_reauthorization_required(_meta, _classification), do: :ok

  defp classify({:ok, _}), do: :ok
  defp classify({:error, :no_token}), do: :no_token
  defp classify({:error, :reauthorization_required}), do: :reauthorization_required
  defp classify({:error, {:refresh_failed, _}}), do: :refresh_failed
  defp classify({:error, {:token_persistence_failed_after_refresh, _}}), do: :persistence_failed
  defp classify({:error, {:lock_timeout, _}}), do: :lock_timeout
  defp classify({:error, {:refresh_crashed, _}}), do: :refresh_crashed
  defp classify({:error, _}), do: :error
end
