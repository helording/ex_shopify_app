defmodule ExShopifyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_shopify_app,
      version: "1.0.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:plug, "~> 1.4"},
      {:guardian, "~> 2.4"},
      {:tesla, "~> 1.11"},
      {:telemetry, "~> 1.0"},
      {:ecto, "~> 3.0"},
      {:mint, "~> 1.0", optional: true},
      # Optional: only needed for ExShopifyApp.AccessToken.Migrations — any host
      # running the bundled migration already has an Ecto SQL repo.
      {:ecto_sql, "~> 3.0", optional: true},
      {:postgrex, ">= 0.0.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:ex_machina, "~> 2.7", only: :test}
    ]
  end

  defp description do
    "Your entrypoint to create a Shopify Application in Elixir."
  end

  defp package() do
    [
      licenses: ["GPL-3.0"],
      links: %{
        "GitHub" => "https://github.com/NexPB/ex_shopify_app"
      }
    ]
  end
end
