# lib/decision_engine/req_llm_config_manager.ex
defmodule DecisionEngine.ReqLLMConfigManager do
  @moduledoc """
  Manages ReqLLM-specific configuration and provider settings.

  This module provides configuration management for the ReqLLM integration,
  including validation, normalization, provider-specific configuration builders,
  and migration utilities from the current LLM configuration format.
  """

  use GenServer
  require Logger
  alias DecisionEngine.ReqLLMConnectionPool
  alias DecisionEngine.ReqLLMResourceMonitor
  alias DecisionEngine.ReqLLMRequestBatcher

  @config_version "1.0"
  @supported_providers [:openai, :anthropic, :ollama, :openrouter, :custom, :lm_studio]

  # Default ReqLLM configuration structure
  @default_config %{
    provider: :openai,
    model: "gpt-4",
    base_url: "https://api.openai.com/v1/chat/completions",
    streaming: true,
    temperature: 0.7,
    max_tokens: 2000,
    timeout: 30000,
    connection_pool: %{
      size: 10,
      max_idle_time: 60000,
      checkout_timeout: 5000
    },
    retry_strategy: %{
      max_retries: 3,
      base_delay: 1000,
      max_delay: 30000,
      backoff_type: :exponential
    },
    error_handling: %{
      circuit_breaker: true,
      rate_limit_handling: true,
      timeout_ms: 30000,
      fallback_enabled: true
    },
    resource_constraints: %{
      max_concurrent_requests: 50,
      max_memory_usage_mb: 512,
      max_cpu_usage_percent: 80.0,
      connection_timeout_ms: 30_000,
      request_timeout_ms: 60_000
    },
    request_batching: %{
      max_batch_size: 10,
      batch_timeout: 1000,
      max_queue_size: 100
    },
    version: @config_version
  }

  # Client API

  @doc """
  Starts the ReqLLM Configuration Manager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Builds ReqLLM configuration for a specific provider.

  ## Parameters
  - provider: Atom representing the provider (:openai, :anthropic, etc.)
  - settings: Map containing provider-specific settings

  ## Returns
  - {:ok, config} with built configuration
  - {:error, reason} if configuration building fails
  """
  @spec build_reqllm_config(atom(), map()) :: {:ok, map()} | {:error, term()}
  def build_reqllm_config(provider, settings) do
    GenServer.call(__MODULE__, {:build_reqllm_config, provider, settings})
  end

  @doc """
  Validates ReqLLM configuration parameters.

  ## Parameters
  - config: Map containing ReqLLM configuration to validate

  ## Returns
  - :ok if configuration is valid
  - {:error, [String.t()]} with list of validation errors
  """
  @spec validate_reqllm_config(map()) :: :ok | {:error, [String.t()]}
  def validate_reqllm_config(config) do
    GenServer.call(__MODULE__, {:validate_reqllm_config, config})
  end

  @doc """
  Normalizes configuration from various formats to ReqLLM format.

  ## Parameters
  - config: Map containing configuration in any supported format

  ## Returns
  - {:ok, normalized_config} with normalized ReqLLM configuration
  - {:error, reason} if normalization fails
  """
  @spec normalize_config(map()) :: {:ok, map()} | {:error, term()}
  def normalize_config(config) do
    GenServer.call(__MODULE__, {:normalize_config, config})
  end

  @doc """
  Migrates configuration from current LLMClient format to ReqLLM format.

  ## Parameters
  - legacy_config: Map containing current LLMClient configuration

  ## Returns
  - {:ok, reqllm_config} with migrated ReqLLM configuration
  - {:error, reason} if migration fails
  """
  @spec migrate_from_legacy(map()) :: {:ok, map()} | {:error, term()}
  def migrate_from_legacy(legacy_config) do
    GenServer.call(__MODULE__, {:migrate_from_legacy, legacy_config})
  end

  @doc """
  Gets provider-specific default settings.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, defaults} with provider-specific default settings
  - {:error, reason} if provider is not supported
  """
  @spec get_provider_defaults(atom()) :: {:ok, map()} | {:error, term()}
  def get_provider_defaults(provider) do
    GenServer.call(__MODULE__, {:get_provider_defaults, provider})
  end

  @doc """
  Updates provider-specific settings in the configuration.

  ## Parameters
  - provider: Atom representing the provider
  - updates: Map containing settings to update

  ## Returns
  - {:ok, updated_config} with updated configuration
  - {:error, reason} if update fails
  """
  @spec update_provider_settings(atom(), map()) :: {:ok, map()} | {:error, term()}
  def update_provider_settings(provider, updates) do
    GenServer.call(__MODULE__, {:update_provider_settings, provider, updates})
  end

  @doc """
  Gets connection pool metrics for a provider.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, metrics} with current pool metrics
  - {:error, reason} if provider not configured
  """
  @spec get_connection_pool_metrics(atom()) :: {:ok, map()} | {:error, term()}
  def get_connection_pool_metrics(provider) do
    ReqLLMConnectionPool.get_pool_metrics(provider)
  end

  @doc """
  Gets connection pool metrics for all configured providers.

  ## Returns
  - Map with provider atoms as keys and metrics as values
  """
  @spec get_all_connection_pool_metrics() :: map()
  def get_all_connection_pool_metrics do
    ReqLLMConnectionPool.get_all_metrics()
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Configuration Manager")

    state = %{
      config: @default_config,
      provider_configs: %{},
      migration_status: :not_started
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:build_reqllm_config, provider, settings}, _from, state) do
    case build_provider_config(provider, settings) do
      {:ok, config} ->
        # Configure connection pool for the provider
        pool_config = Map.get(config, :connection_pool, %{})
        pool_result = ReqLLMConnectionPool.configure_pool(provider, pool_config)

        # Configure resource constraints for the provider
        resource_config = Map.get(config, :resource_constraints, %{})
        resource_result = ReqLLMResourceMonitor.configure_constraints(provider, resource_config)

        # Configure request batching for the provider
        batch_config = Map.get(config, :request_batching, %{})
        batch_result = ReqLLMRequestBatcher.configure_batching(provider, batch_config)

        # Log configuration results
        case {pool_result, resource_result, batch_result} do
          {:ok, :ok, :ok} ->
            Logger.info("Successfully configured all ReqLLM components for #{provider}")

          _ ->
            Logger.warning("Some ReqLLM component configurations failed for #{provider}: pool=#{inspect(pool_result)}, resource=#{inspect(resource_result)}, batch=#{inspect(batch_result)}")
        end

        new_provider_configs = Map.put(state.provider_configs, provider, config)
        new_state = %{state | provider_configs: new_provider_configs}
        {:reply, {:ok, config}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:validate_reqllm_config, config}, _from, state) do
    result = validate_config_internal(config)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:normalize_config, config}, _from, state) do
    result = normalize_config_internal(config)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:migrate_from_legacy, legacy_config}, _from, state) do
    case migrate_legacy_config(legacy_config) do
      {:ok, reqllm_config} ->
        new_state = %{state | migration_status: :completed}
        {:reply, {:ok, reqllm_config}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_provider_defaults, provider}, _from, state) do
    case get_provider_defaults_internal(provider) do
      {:ok, defaults} ->
        {:reply, {:ok, defaults}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_provider_settings, provider, updates}, _from, state) do
    case Map.get(state.provider_configs, provider) do
      nil ->
        {:reply, {:error, "Provider #{provider} not configured"}, state}

      current_config ->
        updated_config = Map.merge(current_config, updates)
        case validate_config_internal(updated_config) do
          :ok ->
            new_provider_configs = Map.put(state.provider_configs, provider, updated_config)
            new_state = %{state | provider_configs: new_provider_configs}
            {:reply, {:ok, updated_config}, new_state}

          {:error, errors} ->
            {:reply, {:error, errors}, state}
        end
    end
  end

  # Private Functions

  defp build_provider_config(provider, settings) when provider in @supported_providers do
    try do
      base_config = get_provider_defaults_internal(provider)

      case base_config do
        {:ok, defaults} ->
          # Merge provider defaults with user settings
          config = Map.merge(defaults, settings)

          # Validate the merged configuration
          case validate_config_internal(config) do
            :ok ->
              {:ok, config}
            {:error, errors} ->
              {:error, "Configuration validation failed: #{Enum.join(errors, ", ")}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Error building provider config for #{provider}: #{inspect(error)}")
        {:error, "Failed to build configuration: #{inspect(error)}"}
    end
  end

  defp build_provider_config(provider, _settings) do
    {:error, "Unsupported provider: #{provider}. Supported providers: #{inspect(@supported_providers)}"}
  end

  defp validate_config_internal(config) do
    errors = []

    # Validate provider
    errors = case Map.get(config, :provider) do
      nil -> ["Provider is required" | errors]
      provider when provider in @supported_providers -> errors
      provider -> ["Unsupported provider: #{provider}" | errors]
    end

    # Validate model
    errors = case Map.get(config, :model) do
      nil -> ["Model is required" | errors]
      model when is_binary(model) and byte_size(model) > 0 -> errors
      _ -> ["Model must be a non-empty string" | errors]
    end

    # Validate base_url
    errors = case Map.get(config, :base_url) do
      nil -> ["Base URL is required" | errors]
      url when is_binary(url) ->
        if String.starts_with?(url, ["http://", "https://"]) do
          errors
        else
          ["Base URL must be a valid HTTP/HTTPS URL" | errors]
        end
      _ -> ["Base URL must be a string" | errors]
    end

    # Validate temperature
    errors = case Map.get(config, :temperature) do
      nil -> errors  # Optional field
      temp when is_number(temp) and temp >= 0.0 and temp <= 2.0 -> errors
      _ -> ["Temperature must be a number between 0.0 and 2.0" | errors]
    end

    # Validate max_tokens
    errors = case Map.get(config, :max_tokens) do
      nil -> errors  # Optional field
      tokens when is_integer(tokens) and tokens > 0 -> errors
      _ -> ["Max tokens must be a positive integer" | errors]
    end

    # Validate timeout
    errors = case Map.get(config, :timeout) do
      nil -> errors  # Optional field
      timeout when is_integer(timeout) and timeout > 0 -> errors
      _ -> ["Timeout must be a positive integer (milliseconds)" | errors]
    end

    # Validate streaming
    errors = case Map.get(config, :streaming) do
      nil -> errors  # Optional field
      streaming when is_boolean(streaming) -> errors
      _ -> ["Streaming must be a boolean" | errors]
    end

    # Validate connection_pool if present
    errors = case Map.get(config, :connection_pool) do
      nil -> errors  # Optional field
      pool when is_map(pool) ->
        validate_connection_pool(pool, errors)
      _ -> ["Connection pool must be a map" | errors]
    end

    # Validate retry_strategy if present
    errors = case Map.get(config, :retry_strategy) do
      nil -> errors  # Optional field
      strategy when is_map(strategy) ->
        validate_retry_strategy(strategy, errors)
      _ -> ["Retry strategy must be a map" | errors]
    end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_connection_pool(pool, errors) do
    errors = case Map.get(pool, :size) do
      nil -> errors
      size when is_integer(size) and size > 0 -> errors
      _ -> ["Connection pool size must be a positive integer" | errors]
    end

    errors = case Map.get(pool, :max_idle_time) do
      nil -> errors
      time when is_integer(time) and time > 0 -> errors
      _ -> ["Connection pool max_idle_time must be a positive integer" | errors]
    end

    case Map.get(pool, :checkout_timeout) do
      nil -> errors
      timeout when is_integer(timeout) and timeout > 0 -> errors
      _ -> ["Connection pool checkout_timeout must be a positive integer" | errors]
    end
  end

  defp validate_retry_strategy(strategy, errors) do
    errors = case Map.get(strategy, :max_retries) do
      nil -> errors
      retries when is_integer(retries) and retries >= 0 -> errors
      _ -> ["Max retries must be a non-negative integer" | errors]
    end

    errors = case Map.get(strategy, :base_delay) do
      nil -> errors
      delay when is_integer(delay) and delay > 0 -> errors
      _ -> ["Base delay must be a positive integer" | errors]
    end

    errors = case Map.get(strategy, :backoff_type) do
      nil -> errors
      type when type in [:exponential, :linear, :constant] -> errors
      _ -> ["Backoff type must be :exponential, :linear, or :constant" | errors]
    end

    case Map.get(strategy, :max_delay) do
      nil -> errors
      delay when is_integer(delay) and delay > 0 -> errors
      _ -> ["Max delay must be a positive integer" | errors]
    end
  end

  defp normalize_config_internal(config) do
    try do
      normalized = config
      |> normalize_keys()
      |> normalize_provider()
      |> normalize_urls()
      |> add_defaults()

      {:ok, normalized}
    rescue
      error ->
        Logger.error("Error normalizing config: #{inspect(error)}")
        {:error, "Failed to normalize configuration: #{inspect(error)}"}
    end
  end

  defp normalize_keys(config) do
    # Convert string keys to atoms and handle common key variations
    config
    |> Enum.map(fn
      {"provider", value} -> {:provider, value}
      {"model", value} -> {:model, value}
      {"base_url", value} -> {:base_url, value}
      {"api_url", value} -> {:base_url, value}  # Map api_url to base_url
      {"endpoint", value} -> {:base_url, value}  # Map endpoint to base_url
      {"api_key", value} -> {:api_key, value}
      {"temperature", value} -> {:temperature, value}
      {"max_tokens", value} -> {:max_tokens, value}
      {"timeout", value} -> {:timeout, value}
      {"streaming", value} -> {:streaming, value}
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
    |> Map.new()
  end

  defp normalize_provider(config) do
    case Map.get(config, :provider) do
      provider when is_binary(provider) ->
        Map.put(config, :provider, String.to_existing_atom(provider))
      _ ->
        config
    end
  rescue
    ArgumentError ->
      # If provider string doesn't exist as atom, keep as string for validation to catch
      config
  end

  defp normalize_urls(config) do
    # Ensure base_url is properly formatted
    case Map.get(config, :base_url) do
      nil -> config
      url when is_binary(url) ->
        # Remove trailing slashes for consistency
        normalized_url = String.trim_trailing(url, "/")
        Map.put(config, :base_url, normalized_url)
      _ -> config
    end
  end

  defp add_defaults(config) do
    # Add default values for missing optional fields
    Map.merge(@default_config, config)
  end

  defp migrate_legacy_config(legacy_config) do
    try do
      # Map legacy LLMClient configuration to ReqLLM format
      reqllm_config = %{
        provider: get_legacy_value(legacy_config, [:provider]),
        model: get_legacy_value(legacy_config, [:model]),
        base_url: get_legacy_value(legacy_config, [:api_url, :endpoint, :base_url]),
        api_key: get_legacy_value(legacy_config, [:api_key]),
        temperature: get_legacy_value(legacy_config, [:temperature], 0.7),
        max_tokens: get_legacy_value(legacy_config, [:max_tokens], 2000),
        timeout: get_legacy_value(legacy_config, [:timeout], 30000),
        streaming: get_legacy_value(legacy_config, [:streaming, :stream], true),
        # Add ReqLLM-specific defaults
        connection_pool: @default_config.connection_pool,
        retry_strategy: @default_config.retry_strategy,
        error_handling: @default_config.error_handling,
        version: @config_version
      }

      # Remove nil values
      reqllm_config = reqllm_config
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      # Normalize and validate
      case normalize_config_internal(reqllm_config) do
        {:ok, normalized} ->
          case validate_config_internal(normalized) do
            :ok ->
              Logger.info("Successfully migrated legacy configuration to ReqLLM format")
              {:ok, normalized}
            {:error, errors} ->
              {:error, "Migration validation failed: #{Enum.join(errors, ", ")}"}
          end
        {:error, reason} ->
          {:error, "Migration normalization failed: #{reason}"}
      end
    rescue
      error ->
        Logger.error("Error migrating legacy config: #{inspect(error)}")
        {:error, "Failed to migrate configuration: #{inspect(error)}"}
    end
  end

  defp get_legacy_value(config, keys, default \\ nil) do
    Enum.find_value(keys, default, fn key ->
      Map.get(config, key) || Map.get(config, Atom.to_string(key))
    end)
  end

  defp get_provider_defaults_internal(provider) when provider in @supported_providers do
    base_defaults = @default_config

    provider_specific = case provider do
      :openai ->
        %{
          provider: :openai,
          model: "gpt-4",
          base_url: "https://api.openai.com/v1/chat/completions",
          temperature: 0.7
        }

      :anthropic ->
        %{
          provider: :anthropic,
          model: "claude-3-5-sonnet-20241022",
          base_url: "https://api.anthropic.com/v1/messages",
          temperature: 0.7
        }

      :ollama ->
        %{
          provider: :ollama,
          model: "llama3.1",
          base_url: "http://localhost:11434/api/chat",
          temperature: 0.7
        }

      :openrouter ->
        %{
          provider: :openrouter,
          model: "anthropic/claude-3.5-sonnet",
          base_url: "https://openrouter.ai/api/v1/chat/completions",
          temperature: 0.7
        }

      :lm_studio ->
        %{
          provider: :lm_studio,
          model: "local-model",
          base_url: "http://localhost:1234/v1/chat/completions",
          temperature: 0.7
        }

      :custom ->
        %{
          provider: :custom,
          model: "custom-model",
          base_url: "https://api.example.com/v1/chat/completions",
          temperature: 0.7
        }
    end

    merged_config = Map.merge(base_defaults, provider_specific)
    {:ok, merged_config}
  end

  defp get_provider_defaults_internal(provider) do
    {:error, "Unsupported provider: #{provider}. Supported providers: #{inspect(@supported_providers)}"}
  end
end
