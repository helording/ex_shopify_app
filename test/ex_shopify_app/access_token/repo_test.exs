defmodule ExShopifyApp.AccessToken.RepoTest do
  # async: false — refreshes run in spawned processes (Task.async_stream), so the Tesla
  # adapter mock is set in Mox global mode, and a shared, non-sandboxed Postgres lets
  # FOR UPDATE row locks actually contend across connections. RepoCase supplies the shared
  # imports/aliases, global Mox mode, and the per-test table cleanup.
  use ExShopifyApp.RepoCase, async: false

  # Asserts every `expect`ed call count was met (and not exceeded) at the end of a test.
  setup :verify_on_exit!

  # --- put_token / fetch_token ----------------------------------------------

  describe "put_token/2 and fetch_token/1" do
    test "fetch_token returns {:error, :no_token} for a missing row" do
      assert {:error, :no_token} = TestStore.fetch_token("missing.myshopify.com")
    end

    test "put_token upserts by shopify_domain" do
      domain = "shop.myshopify.com"

      :ok =
        TestStore.put_token(
          domain,
          build(:token, shopify_domain: domain, access_token: "shpat_first")
        )

      :ok =
        TestStore.put_token(
          domain,
          build(:token, shopify_domain: domain, access_token: "shpat_second")
        )

      assert TestRepo.aggregate(Token, :count) == 1
      assert %Token{access_token: "shpat_second"} = stored(domain)
    end

    test "put_token normalizes a https:// prefixed domain" do
      :ok =
        TestStore.put_token(
          "https://shop.myshopify.com",
          build(:token, shopify_domain: "https://shop.myshopify.com")
        )

      assert {:ok, %Token{shopify_domain: "shop.myshopify.com"}} =
               TestStore.fetch_token("shop.myshopify.com")
    end
  end

  # --- valid_token ------------------------------------------------------------

  describe "valid_token/2" do
    test "no stored token returns {:error, :no_token}" do
      assert {:error, :no_token} = TestStore.valid_token(%{shopify_domain: "nope.myshopify.com"})
    end

    test "a fresh token is returned without an HTTP call" do
      expect_no_refresh()
      domain = "fresh.myshopify.com"
      insert(:token, shopify_domain: domain, access_token: "shpat_fresh")

      assert {:ok, %Token{access_token: "shpat_fresh", refresh_generation: 0}} =
               TestStore.valid_token(%{shopify_domain: domain})
    end

    test "a hard-expired token refreshes and persists before returning" do
      expect_refresh(1)
      domain = "expired.myshopify.com"
      insert(:expired_token, shopify_domain: domain)

      assert {:ok,
              %Token{access_token: "shpat_new", refresh_token: "shprt_new", refresh_generation: 1}} =
               TestStore.valid_token(%{shopify_domain: domain})

      # Persisted before returning.
      assert %Token{refresh_token: "shprt_new", refresh_generation: 1} = stored(domain)
    end

    test "a stale token refreshes synchronously and persists by default" do
      expect_refresh(1)
      domain = "stale.myshopify.com"
      # 3300s into a 3600s lifetime: inside the soft window, not yet hard-expired.
      insert(:stale_token, shopify_domain: domain)

      assert {:ok, %Token{access_token: "shpat_new"}} =
               TestStore.valid_token(%{shopify_domain: domain}, soft_window: [jitter: 0])

      assert %Token{refresh_token: "shprt_new"} = stored(domain)
    end

    test "an expired refresh token returns :reauthorization_required without an HTTP call" do
      expect_no_refresh()
      domain = "dead.myshopify.com"
      insert(:token, shopify_domain: domain, issued: hours_ago(3000))

      assert {:error, :reauthorization_required} =
               TestStore.valid_token(%{shopify_domain: domain})
    end
  end

  # --- refresh_token: Shopify error handling ---------------------------------

  describe "refresh_token/2 Shopify errors" do
    test "invalid_grant maps to :reauthorization_required and leaves the token unchanged" do
      domain = "ig.myshopify.com"
      insert(:expired_token, shopify_domain: domain)

      stub_error(%{"error" => "invalid_grant"}, 400)

      assert {:error, :reauthorization_required} =
               TestStore.refresh_token(%{shopify_domain: domain})

      assert %Token{refresh_token: "shprt_old", refresh_generation: 0} = stored(domain)
    end

    test "a 5xx maps to {:refresh_failed, _}, leaves the token, and records last_refresh_error" do
      domain = "boom.myshopify.com"
      insert(:expired_token, shopify_domain: domain)
      stub_error(%{"error" => "server"}, 503)

      assert {:error, {:refresh_failed, %Tesla.Env{status: 503}}} =
               TestStore.refresh_token(%{shopify_domain: domain})

      token = stored(domain)
      assert token.refresh_token == "shprt_old"
      assert token.refresh_generation == 0
      assert token.last_refresh_error =~ "refresh_failed:http_503"
    end

    test "stale_while_error returns the still-valid token when a refresh fails" do
      domain = "swr.myshopify.com"
      insert(:stale_token, shopify_domain: domain)
      stub_error(%{"error" => "server"}, 503)

      assert {:ok, %Token{access_token: "shpat_old"}} =
               TestStore.valid_token(%{shopify_domain: domain},
                 soft_window: [jitter: 0],
                 stale_while_error: true
               )
    end
  end

  # --- refresh_token: heartbeat window ----------------------------------------

  describe "refresh_token/2 with :refresh_token_window" do
    test "rotates a fresh token whose refresh token expires inside the window" do
      expect_refresh(1)
      domain = "keepalive.myshopify.com"
      # Access token fresh (just issued), refresh token expiring in 3 days.
      insert(:token, shopify_domain: domain, refresh_token_expires_in: 3 * 24 * 60 * 60)

      assert {:ok, %Token{refresh_token: "shprt_new", refresh_generation: 1}} =
               TestStore.refresh_token(%{shopify_domain: domain},
                 refresh_token_window: 7 * 24 * 60 * 60
               )
    end

    test "without the option a fresh token is returned with no Shopify call" do
      expect_no_refresh()
      domain = "keepalive-noop.myshopify.com"
      insert(:token, shopify_domain: domain, refresh_token_expires_in: 3 * 24 * 60 * 60)

      assert {:ok, %Token{refresh_token: "shprt_old", refresh_generation: 0}} =
               TestStore.refresh_token(%{shopify_domain: domain})
    end
  end

  # --- concurrency ------------------------------------------------------------

  describe "concurrent refreshes" do
    test "for one shop produce exactly one Shopify call and one generation bump" do
      domain = "concurrent.myshopify.com"
      insert(:expired_token, shopify_domain: domain)
      # Exactly one expected call: the winner of the row lock refreshes; the other nine
      # find the token already current and make no call. A second call would raise.
      expect_refresh(1, delay: 30)

      results =
        1..10
        |> Task.async_stream(fn _ -> TestStore.refresh_token(%{shopify_domain: domain}) end,
          max_concurrency: 10,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &match?({:ok, %Token{refresh_token: "shprt_new"}}, &1))
      assert %Token{refresh_generation: 1} = stored(domain)
    end

    test "for different shops proceed independently" do
      insert(:expired_token, shopify_domain: "a.myshopify.com")
      insert(:expired_token, shopify_domain: "b.myshopify.com")
      expect_refresh(2, delay: 10)

      t1 = Task.async(fn -> TestStore.refresh_token(%{shopify_domain: "a.myshopify.com"}) end)
      t2 = Task.async(fn -> TestStore.refresh_token(%{shopify_domain: "b.myshopify.com"}) end)

      assert {:ok, %Token{}} = Task.await(t1)
      assert {:ok, %Token{}} = Task.await(t2)
    end
  end

  # --- persistence failure after a successful refresh ------------------------

  test "persistence failure after Shopify success is critical and emits telemetry" do
    domain = "persistfail.myshopify.com"
    insert(:expired_token, shopify_domain: domain)
    expect_refresh(1)

    handler = "persist-failed-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:ex_shopify_app, :access_token, :refresh, :persistence_failed],
      fn event, measurements, meta, _ ->
        send(test_pid, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, {:token_persistence_failed_after_refresh, :persist_boom}} =
             ExShopifyApp.FailingStore.refresh_token(%{shopify_domain: domain})

    # Shopify was called (expect_refresh(1)), but the row is untouched (rolled back).
    assert %Token{refresh_token: "shprt_old", refresh_generation: 0} = stored(domain)

    assert_receive {:telemetry, [:ex_shopify_app, :access_token, :refresh, :persistence_failed],
                    _m, %{shopify_domain: ^domain}}
  end

  # The held-row-lock / lock_timeout path lives in its own module
  # (ExShopifyApp.AccessToken.LockTimeoutTest): it needs two independent connections, which
  # the shared-mode sandbox used here cannot provide.

  # --- helpers ---------------------------------------------------------------

  # Expect *exactly* `n` successful Shopify refresh calls. verify_on_exit! fails the test
  # if fewer happen; an (n+1)th call raises Mox.UnexpectedCallError in the caller. This
  # replaces the old Agent call counter with a native Mox assertion.
  defp expect_refresh(n, opts \\ []) do
    delay = Keyword.get(opts, :delay, 0)

    expect(MockTeslaAdapter, :call, n, fn %{method: :post}, _opts ->
      if delay > 0, do: Process.sleep(delay)
      {:ok, json_response(token_response(), status: 200)}
    end)
  end

  # Assert that no Shopify refresh call is made: a stub that fails the test if invoked.
  defp expect_no_refresh do
    stub(MockTeslaAdapter, :call, fn _env, _opts ->
      flunk("expected no Shopify refresh call, but the adapter was invoked")
    end)
  end

  # Stub the Shopify endpoint to return an error response (call count is not asserted).
  defp stub_error(body, status) do
    stub(MockTeslaAdapter, :call, fn _env, _opts ->
      {:ok, json_response(body, status: status)}
    end)
  end

  defp hours_ago(h), do: DateTime.add(DateTime.utc_now(), -h, :hour)
end
