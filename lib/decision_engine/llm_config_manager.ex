# lib/decision_engine/llm_config_manager.ex
defmodule DecisionEngine.LLMConfigManager do
  @moduledoc """
  Manages LLM configuration with persistent storage (excluding API keys) and session-based API key management.

  This module provides centralized configuration management for all LLM features in the application,
  ensuring consistent settings across different AI capabilities while maintaining security by not
  persisting sensitive API keys.
  """

  use GenServer
  require Logger

  @config_version "1.0"
  @default_config %{
    provider: "openai",
    model: "gpt-4",
    endpoint: "https://api.openai.com/v1/chat/completions",
    streaming: true,
    temperature: 0.7,
    max_tokens: 2000,
    timeout: 30000,
    version: @config_version
  }

  @supported_providers ["openai", "anthropic", "ollama", "openrouter", "custom", "lm_studio"]

  # Client API

  @doc """
  Starts the LLM Configuration Manager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves LLM configuration to persistent storage (excluding API keys).

  ## Parameters
  - config: Map containing LLM configuration parameters

  ## Returns
  - :ok on successful save
  - {:error, term()} on failure
  """
  @spec save_config(map()) :: :ok | {:error, term()}
  def save_config(config) do
    GenServer.call(__MODULE__, {:save_config, config})
  end

  @doc """
  Loads LLM configuration from persistent storage.

  ## Returns
  - {:ok, map()} with loaded configuration
  - {:error, term()} if loading fails or no configuration exists
  """
  @spec load_config() :: {:ok, map()} | {:error, term()}
  def load_config() do
    GenServer.call(__MODULE__, :load_config)
  end

  @doc """
  Validates LLM configuration parameters.

  ## Parameters
  - config: Map containing configuration to validate

  ## Returns
  - :ok if configuration is valid
  - {:error, [String.t()]} with list of validation errors
  """
  @spec validate_config(map()) :: :ok | {:error, [String.t()]}
  def validate_config(config) do
    GenServer.call(__MODULE__, {:validate_config, config})
  end

  @doc """
  Sets API key for a specific provider in session storage (memory only).

  ## Parameters
  - provider: String provider name
  - api_key: String API key value

  ## Returns
  - :ok always (API keys are stored in memory)
  """
  @spec set_api_key(String.t(), String.t()) :: :ok
  def set_api_key(provider, api_key) do
    GenServer.call(__MODULE__, {:set_api_key, provider, api_key})
  end

  @doc """
  Gets current complete configuration including session API keys.

  ## Returns
  - {:ok, map()} with complete configuration including API keys
  - {:error, term()} if no configuration is available
  """
  @spec get_current_config() :: {:ok, map()} | {:error, term()}
  def get_current_config() do
    GenServer.call(__MODULE__, :get_current_config)
  end

  @doc """
  Tests connection to LLM provider with given configuration.

  ## Parameters
  - config: Map containing complete configuration including API key

  ## Returns
  - :ok if connection test succeeds
  - {:error, term()} if connection fails
  """
  @spec test_connection(map()) :: :ok | {:error, term()}
  def test_connection(config) do
    GenServer.call(__MODULE__, {:test_connection, config}, 30_000)
  end

  @doc """
  Gets API key for the current provider from session storage.

  ## Returns
  - {:ok, String.t()} if API key is available
  - {:error, :not_found} if no API key is set
  """
  @spec get_api_key() :: {:ok, String.t()} | {:error, :not_found}
  def get_api_key() do
    GenServer.call(__MODULE__, :get_api_key)
  end

  @doc """
  Clears API key from session storage.
  """
  @spec clear_api_key() :: :ok
  def clear_api_key() do
    GenServer.call(__MODULE__, :clear_api_key)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize state with default config and empty API key storage
    state = %{
      config: @default_config,
      api_keys: %{},  # provider -> api_key mapping
      current_provider: @default_config.provider
    }

    # Try to load saved configuration on startup
    case load_config_from_storage() do
      {:ok, saved_config} ->
        Logger.info("Loaded LLM configuration from storage")
        {:ok, %{state | config: saved_config, current_provider: saved_config.provider}}

      {:error, reason} ->
        Logger.info("Using default LLM configuration: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:save_config, config}, _from, state) do
    case validate_config_internal(config) do
      :ok ->
        # Add metadata and save to storage
        config_with_metadata = config
        |> Map.put(:created_at, DateTime.utc_now())
        |> Map.put(:version, @config_version)

        case save_config_to_storage(config_with_metadata) do
          :ok ->
            new_state = %{state |
              config: config_with_metadata,
              current_provider: config_with_metadata.provider || config_with_metadata["provider"]
            }
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  @impl true
  def handle_call(:load_config, _from, state) do
    case load_config_from_storage() do
      {:ok, config} ->
        new_state = %{state |
          config: config,
          current_provider: config.provider || config["provider"]
        }
        {:reply, {:ok, config}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:validate_config, config}, _from, state) do
    result = validate_config_internal(config)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_api_key, provider, api_key}, _from, state) do
    # Normalize provider to match current_provider format
    normalized_provider = if is_binary(provider), do: provider, else: to_string(provider)
    new_api_keys = Map.put(state.api_keys, normalized_provider, api_key)
    new_state = %{state | api_keys: new_api_keys}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_current_config, _from, state) do
    # Merge persistent config with session API key
    current_provider = to_string(state.current_provider)
    api_key = Map.get(state.api_keys, current_provider)

    # Check if the current provider requires an API key (also check endpoint)
    endpoint = get_config_value(state.config, :endpoint) || ""
    provider_requires_api_key = provider_requires_api_key?(current_provider) and not is_local_endpoint?(endpoint)

    complete_config = case {api_key, provider_requires_api_key} do
      {nil, true} ->
        # Provider requires API key but none is set
        {:error, :api_key_required}

      {nil, false} ->
        # Provider doesn't require API key (e.g., local providers)
        {:ok, state.config}

      {key, _} ->
        # API key is available, add it to config
        config_with_key = state.config
        |> Map.put(:api_key, key)
        |> Map.put("api_key", key)  # Support both atom and string keys

        {:ok, config_with_key}
    end

    {:reply, complete_config, state}
  end

  @impl true
  def handle_call({:test_connection, config}, _from, state) do
    result = test_llm_connection(config)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_api_key, _from, state) do
    current_provider = to_string(state.current_provider)
    case Map.get(state.api_keys, current_provider) do
      nil -> {:reply, {:error, :not_found}, state}
      api_key -> {:reply, {:ok, api_key}, state}
    end
  end

  @impl true
  def handle_call(:clear_api_key, _from, state) do
    current_provider = to_string(state.current_provider)
    new_api_keys = Map.delete(state.api_keys, current_provider)
    new_state = %{state | api_keys: new_api_keys}
    {:reply, :ok, new_state}
  end

  # Private Functions

  defp provider_requires_api_key?(provider) do
    # Local providers that don't require API keys
    local_providers = ["ollama", "lm_studio", "local"]

    normalized_provider = provider |> to_string() |> String.downcase()

    # Check if it's a local provider
    not (normalized_provider in local_providers)
  end

  defp is_local_endpoint?(endpoint) do
    endpoint = endpoint |> to_string() |> String.downcase()

    # Check if endpoint points to local/localhost
    String.contains?(endpoint, "localhost") or
    String.contains?(endpoint, "127.0.0.1") or
    String.contains?(endpoint, "0.0.0.0")
  end

  defp validate_config_internal(config) do
    errors = []

    # Validate provider
    errors = case get_config_value(config, :provider) do
      nil -> ["Provider is required" | errors]
      provider when provider in @supported_providers -> errors
      provider -> ["Unsupported provider: #{provider}. Supported: #{Enum.join(@supported_providers, ", ")}" | errors]
    end

    # Validate model
    errors = case get_config_value(config, :model) do
      nil -> ["Model is required" | errors]
      model when is_binary(model) and byte_size(model) > 0 -> errors
      _ -> ["Model must be a non-empty string" | errors]
    end

    # Validate endpoint
    errors = case get_config_value(config, :endpoint) do
      nil -> ["Endpoint is required" | errors]
      endpoint when is_binary(endpoint) ->
        if String.starts_with?(endpoint, ["http://", "https://"]) do
          errors
        else
          ["Endpoint must be a valid HTTP/HTTPS URL" | errors]
        end
      _ -> ["Endpoint must be a string" | errors]
    end

    # Validate temperature
    errors = case get_config_value(config, :temperature) do
      nil -> errors  # Optional field
      temp when is_number(temp) and temp >= 0.0 and temp <= 1.0 -> errors
      _ -> ["Temperature must be a number between 0.0 and 1.0" | errors]
    end

    # Validate max_tokens
    errors = case get_config_value(config, :max_tokens) do
      nil -> errors  # Optional field
      tokens when is_integer(tokens) and tokens > 0 -> errors
      _ -> ["Max tokens must be a positive integer" | errors]
    end

    # Validate timeout
    errors = case get_config_value(config, :timeout) do
      nil -> errors  # Optional field
      timeout when is_integer(timeout) and timeout > 0 -> errors
      _ -> ["Timeout must be a positive integer (milliseconds)" | errors]
    end

    # Validate streaming
    errors = case get_config_value(config, :streaming) do
      nil -> errors  # Optional field
      streaming when is_boolean(streaming) -> errors
      _ -> ["Streaming must be a boolean" | errors]
    end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp get_config_value(config, key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp save_config_to_storage(config) do
    try do
      # Convert to JSON-serializable format (string keys and DateTime to ISO string)
      json_config = config
      |> Enum.map(fn
        {k, %DateTime{} = dt} -> {to_string(k), DateTime.to_iso8601(dt)}
        {k, v} -> {to_string(k), v}
      end)
      |> Map.new()

      storage_data = %{"llm_config" => json_config}

      # In a real Phoenix app, this would use JavaScript interop to save to localStorage
      # For now, we'll simulate storage by saving to a file
      storage_path = Path.join([Application.app_dir(:decision_engine, "priv"), "llm_config.json"])

      # Ensure directory exists
      storage_path |> Path.dirname() |> File.mkdir_p!()

      case Jason.encode(storage_data, pretty: true) do
        {:ok, json_string} ->
          case File.write(storage_path, json_string) do
            :ok ->
              Logger.debug("LLM configuration saved to #{storage_path}")
              :ok
            {:error, reason} ->
              Logger.error("Failed to write LLM config to file: #{inspect(reason)}")
              {:error, "Failed to save configuration: #{inspect(reason)}"}
          end

        {:error, reason} ->
          Logger.error("Failed to encode LLM config to JSON: #{inspect(reason)}")
          {:error, "Failed to encode configuration: #{inspect(reason)}"}
      end
    rescue
      error ->
        Logger.error("Exception saving LLM config: #{inspect(error)}")
        {:error, "Exception during save: #{inspect(error)}"}
    end
  end

  defp load_config_from_storage() do
    try do
      storage_path = Path.join([Application.app_dir(:decision_engine, "priv"), "llm_config.json"])

      case File.read(storage_path) do
        {:ok, json_string} ->
          case Jason.decode(json_string) do
            {:ok, %{"llm_config" => config_data}} ->
              # Convert string keys back to atoms and parse DateTime for internal use
              config = config_data
              |> Enum.map(fn
                {"created_at", dt_string} when is_binary(dt_string) ->
                  case DateTime.from_iso8601(dt_string) do
                    {:ok, dt, _} -> {:created_at, dt}
                    _ -> {:created_at, dt_string}  # Keep as string if parsing fails
                  end
                {k, v} -> {String.to_existing_atom(k), v}
              end)
              |> Map.new()

              # Validate loaded config
              case validate_config_internal(config) do
                :ok ->
                  Logger.debug("LLM configuration loaded from #{storage_path}")
                  {:ok, config}
                {:error, errors} ->
                  Logger.warning("Loaded LLM config is invalid: #{inspect(errors)}")
                  {:error, "Invalid saved configuration: #{Enum.join(errors, ", ")}"}
              end

            {:ok, _} ->
              {:error, "Invalid configuration file format"}

            {:error, reason} ->
              Logger.error("Failed to decode LLM config JSON: #{inspect(reason)}")
              {:error, "Failed to parse configuration file: #{inspect(reason)}"}
          end

        {:error, :enoent} ->
          {:error, "No saved configuration found"}

        {:error, reason} ->
          Logger.error("Failed to read LLM config file: #{inspect(reason)}")
          {:error, "Failed to read configuration file: #{inspect(reason)}"}
      end
    rescue
      ArgumentError ->
        # This happens when trying to convert unknown string to existing atom
        Logger.warning("LLM config contains unknown keys, using defaults")
        {:error, "Configuration contains unknown keys"}

      error ->
        Logger.error("Exception loading LLM config: #{inspect(error)}")
        {:error, "Exception during load: #{inspect(error)}"}
    end
  end

  defp test_llm_connection(config) do
    try do
      # Create a simple test prompt
      test_prompt = "Hello, this is a connection test. Please respond with 'OK'."

      # Convert config to format expected by LLMClient
      llm_config = %{
        provider: String.to_existing_atom(get_config_value(config, :provider)),
        api_url: get_config_value(config, :endpoint),
        api_key: get_config_value(config, :api_key),
        model: get_config_value(config, :model),
        temperature: get_config_value(config, :temperature) || 0.1,
        max_tokens: min(get_config_value(config, :max_tokens) || 100, 100)  # Limit for test
      }

      case DecisionEngine.ReqLLMMigrationCoordinator.generate_text(test_prompt, llm_config) do
        {:ok, _response} ->
          Logger.info("LLM connection test successful for provider #{llm_config.provider}")
          :ok

        {:error, reason} ->
          Logger.warning("LLM connection test failed: #{inspect(reason)}")
          {:error, "Connection test failed: #{inspect(reason)}"}
      end
    rescue
      error ->
        Logger.error("Exception during LLM connection test: #{inspect(error)}")
        {:error, "Connection test exception: #{inspect(error)}"}
    end
  end
end
