defmodule ExShopifyApp.AccessToken.HeartbeatTest do
  # async: false — the tick runs in a spawned GenServer, so the Tesla adapter mock is set
  # in Mox global mode, against the shared, non-sandboxed Postgres. RepoCase supplies the
  # shared imports/aliases, global Mox mode, and the per-test table cleanup.
  use ExShopifyApp.RepoCase, async: false

  alias ExShopifyApp.AccessToken.Heartbeat

  @week 7 * 24 * 60 * 60

  setup do
    # Default: every refresh succeeds, returning a rotated token. Call counts aren't
    # asserted here (tests check resulting token state), so a stub fits; a test can
    # override it with its own stub.
    stub(MockTeslaAdapter, :call, fn %{method: :post}, _opts ->
      {:ok,
       json_response(
         token_response(%{"access_token" => "shpat_rotated", "refresh_token" => "shprt_rotated"}),
         status: 200
       )}
    end)

    :ok
  end

  describe "tick" do
    test "refreshes only chains whose refresh token expires inside the window" do
      insert(:token,
        shopify_domain: "due.myshopify.com",
        refresh_token_expires_in: 3 * 24 * 60 * 60
      )

      insert(:token,
        shopify_domain: "fine.myshopify.com",
        refresh_token_expires_in: 60 * 24 * 60 * 60
      )

      insert(:lifetime_token, shopify_domain: "lifetime.myshopify.com")

      run_tick([])

      assert %Token{refresh_token: "shprt_rotated", refresh_generation: 1} =
               stored("due.myshopify.com")

      assert %Token{refresh_token: "shprt_old", refresh_generation: 0} =
               stored("fine.myshopify.com")

      assert %Token{refresh_token: nil, refresh_generation: 0} =
               stored("lifetime.myshopify.com")
    end

    test "a failing refresh logs and does not crash the process" do
      insert(:token,
        shopify_domain: "flaky.myshopify.com",
        refresh_token_expires_in: 3 * 24 * 60 * 60
      )

      stub(MockTeslaAdapter, :call, fn _env, _opts ->
        {:ok, json_response(%{"error" => "server"}, status: 503)}
      end)

      run_tick([])

      assert %Token{refresh_token: "shprt_old", refresh_generation: 0} =
               stored("flaky.myshopify.com")
    end

    test "respects :batch_limit, taking the chains closest to expiry first" do
      insert(:token,
        shopify_domain: "soonest.myshopify.com",
        refresh_token_expires_in: 1 * 24 * 60 * 60
      )

      insert(:token,
        shopify_domain: "later.myshopify.com",
        refresh_token_expires_in: 5 * 24 * 60 * 60
      )

      run_tick(batch_limit: 1)

      assert %Token{refresh_generation: 1} = stored("soonest.myshopify.com")
      assert %Token{refresh_generation: 0} = stored("later.myshopify.com")
    end
  end

  defp run_tick(opts) do
    {:ok, pid} =
      Heartbeat.start_link(
        Keyword.merge(
          [
            store: TestStore,
            repo: TestRepo,
            window: @week,
            # Long enough that the scheduled tick never fires during the test.
            interval: :timer.hours(6),
            name: nil
          ],
          opts
        )
      )

    send(pid, :tick)
    # get_state only returns once the :tick message has been processed.
    :sys.get_state(pid)
    GenServer.stop(pid)
  end
end
