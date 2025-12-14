# config/dev.exs
import Config

config :decision_engine, DecisionEngineWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "your_dev_secret_key_base_at_least_64_chars_long_generate_with_mix_phx_gen_secret",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:decision_engine, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:decision_engine, ~w(--watch)]}
  ]

config :decision_engine, DecisionEngineWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/decision_engine_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, :console, format: "[$level] $message\n"

# Reduce log level to minimize connection error noise
config :logger, level: :info
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
