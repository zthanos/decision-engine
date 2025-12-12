# config/config.exs
import Config

config :decision_engine,
  generators: [timestamp_type: :utc_datetime]

config :decision_engine, DecisionEngineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DecisionEngineWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: DecisionEngine.PubSub,
  live_view: [signing_salt: "your_secret_salt"]

config :esbuild,
  version: "0.17.11",
  decision_engine: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.0",
  decision_engine: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure MIME types for Server-Sent Events
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
