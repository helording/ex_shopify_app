defmodule ExShopifyApp.AccessToken.LockTimeoutTest do
  @moduledoc """
  The locked-refresh `lock_timeout` path, exercised against real Postgres.

  Deliberately does NOT use `ExShopifyApp.RepoCase`: that puts the sandbox in shared mode,
  which funnels every process onto a single connection. A lock held there would starve the
  refresh path at connection *checkout* (a queue timeout), never reaching the row. Here each
  process checks out its own real (`sandbox: false`) connection, so the `FOR UPDATE` lock
  genuinely contends across connections and `SET LOCAL lock_timeout` actually fires.

  Real connections auto-commit (nothing rolls back), so the test cleans up its row.

  `async: false`: it commits to a shared table, so it must not run alongside other tests.
  """
  use ExUnit.Case, async: false

  import ExShopifyApp.Factory, only: [build: 2]

  alias ExShopifyApp.{TestRepo, TestStore}

  @domain "locked.myshopify.com"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo, sandbox: false)

    delete_row()
    TestRepo.insert!(build(:expired_token, shopify_domain: @domain))

    on_exit(fn ->
      # on_exit runs in a separate process, so it needs its own real connection.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo, sandbox: false)
      delete_row()
    end)

    :ok
  end

  test "a held row lock surfaces {:error, {:lock_timeout, _}}" do
    parent = self()

    holder =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo, sandbox: false)

        TestRepo.transaction(fn ->
          TestRepo.query!(
            "SELECT shopify_domain FROM shopify_access_tokens WHERE shopify_domain = $1 FOR UPDATE",
            [@domain]
          )

          send(parent, :locked)

          receive do
            :release -> :ok
          after
            1000 -> :ok
          end
        end)
      end)

    assert_receive :locked, 500

    assert {:error, {:lock_timeout, _reason}} =
             TestStore.refresh_token(%{shopify_domain: @domain}, lock_timeout: 100)

    send(holder.pid, :release)
    Task.await(holder)
  end

  defp delete_row do
    TestRepo.query!("DELETE FROM shopify_access_tokens WHERE shopify_domain = $1", [@domain])
  end
end
