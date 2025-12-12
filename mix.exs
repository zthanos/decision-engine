# mix.exs - Updated with Phoenix dependencies
defmodule DecisionEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :decision_engine,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {DecisionEngine.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.10"},
      {:phoenix_live_view, "~> 0.20.2"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.2"},
      {:req, "~> 0.4"},
      {:finch, "~> 0.18"},
      {:gettext, "~> 0.24"},
      {:ex_json_schema, "~> 0.10"},
      {:earmark, "~> 1.4"},
      {:html_sanitize_ex, "~> 1.4"},
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind decision_engine", "esbuild decision_engine"],
      "assets.deploy": [
        "tailwind decision_engine --minify",
        "esbuild decision_engine --minify",
        "phx.digest"
      ]
    ]
  end
end
