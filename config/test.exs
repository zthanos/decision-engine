# config/test.exs
import Config

config :decision_engine, DecisionEngineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_chars_long_for_testing_purposes_only",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

# Ensure the application starts for tests
config :decision_engine, :start_application, true

# Configure LM Studio for testing
config :decision_engine, :llm_config,
  provider: :openai,
  api_key: "test-key",
  base_url: "http://localhost:1234/v1",
  model: "local-model",
  timeout: 30000
