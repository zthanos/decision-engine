# lib/decision_engine/reflection_config.ex
defmodule DecisionEngine.ReflectionConfig do
  @moduledoc """
  Manages reflection system configuration with validation, persistence, and hot-reloading.

  This module provides centralized configuration management for the agentic reflection
  pattern implementation, ensuring proper parameter validation and configuration persistence.
  """

  use GenServer
  require Logger

  @config_version "1.0"
  @default_config %{
    enabled: false,
    max_iterations: 3,
    quality_threshold: 0.75,
    timeout_ms: 300_000,  # 5 minutes
    custom_prompts: %{
      evaluation: nil,
      refinement: nil
    },
    quality_weights: %{
      completeness: 0.30,
      accuracy: 0.25,
      consistency: 0.25,
      usability: 0.20
    },
    version: @config_version
  }

  # Client API

  @doc """
  Starts the Reflection Configuration Manager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves reflection configuration to persistent storage.

  ## Parameters
  - config: Map containing reflection configuration parameters

  ## Returns
  - :ok on successful save
  - {:error, term()} on failure
  """
  @spec save_config(map()) :: :ok | {:error, term()}
  def save_config(config) do
    GenServer.call(__MODULE__, {:save_config, config})
  end

  @doc """
  Loads reflection configuration from persistent storage.

  ## Returns
  - {:ok, map()} with loaded configuration
  - {:error, term()} if loading fails or no configuration exists
  """
  @spec load_config() :: {:ok, map()} | {:error, term()}
  def load_config() do
    GenServer.call(__MODULE__, :load_config)
  end

  @doc """
  Gets current reflection configuration.

  ## Returns
  - {:ok, map()} with current configuration
  - {:error, term()} if no configuration is available
  """
  @spec get_current_config() :: {:ok, map()} | {:error, term()}
  def get_current_config() do
    GenServer.call(__MODULE__, :get_current_config)
  end

  @doc """
  Validates reflection configuration parameters.

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
  Updates specific configuration parameters without full replacement.

  ## Parameters
  - updates: Map containing configuration updates

  ## Returns
  - :ok on successful update
  - {:error, term()} on failure
  """
  @spec update_config(map()) :: :ok | {:error, term()}
  def update_config(updates) do
    GenServer.call(__MODULE__, {:update_config, updates})
  end

  @doc """
  Resets configuration to default values.

  ## Returns
  - :ok always
  """
  @spec reset_to_defaults() :: :ok
  def reset_to_defaults() do
    GenServer.call(__MODULE__, :reset_to_defaults)
  end

  @doc """
  Checks if reflection is currently enabled.

  ## Returns
  - true if reflection is enabled, false otherwise
  """
  @spec reflection_enabled?() :: boolean()
  def reflection_enabled?() do
    case get_current_config() do
      {:ok, config} -> Map.get(config, :enabled, false)
      {:error, _} -> false
    end
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize state with default config
    state = %{
      config: @default_config,
      config_file_path: get_config_file_path()
    }

    # Try to load saved configuration on startup
    case load_config_from_storage(state.config_file_path) do
      {:ok, saved_config} ->
        Logger.info("Loaded reflection configuration from storage")
        {:ok, %{state | config: saved_config}}

      {:error, reason} ->
        Logger.info("Using default reflection configuration: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:save_config, config}, _from, state) do
    case validate_config_internal(config) do
      :ok ->
        # Add metadata and save to storage
        config_with_metadata = config
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Map.put(:version, @config_version)

        case save_config_to_storage(config_with_metadata, state.config_file_path) do
          :ok ->
            new_state = %{state | config: config_with_metadata}
            Logger.info("Reflection configuration saved successfully")
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
    case load_config_from_storage(state.config_file_path) do
      {:ok, config} ->
        new_state = %{state | config: config}
        {:reply, {:ok, config}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_current_config, _from, state) do
    {:reply, {:ok, state.config}, state}
  end

  @impl true
  def handle_call({:validate_config, config}, _from, state) do
    result = validate_config_internal(config)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_config, updates}, _from, state) do
    # Merge updates with current config
    updated_config = Map.merge(state.config, updates)

    case validate_config_internal(updated_config) do
      :ok ->
        config_with_metadata = updated_config
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Map.put(:version, @config_version)

        case save_config_to_storage(config_with_metadata, state.config_file_path) do
          :ok ->
            new_state = %{state | config: config_with_metadata}
            Logger.info("Reflection configuration updated successfully")
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  @impl true
  def handle_call(:reset_to_defaults, _from, state) do
    default_with_metadata = @default_config
    |> Map.put(:updated_at, DateTime.utc_now())
    |> Map.put(:version, @config_version)

    case save_config_to_storage(default_with_metadata, state.config_file_path) do
      :ok ->
        new_state = %{state | config: default_with_metadata}
        Logger.info("Reflection configuration reset to defaults")
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.warning("Failed to save default config: #{inspect(reason)}")
        new_state = %{state | config: default_with_metadata}
        {:reply, :ok, new_state}
    end
  end

  # Private Functions

  defp validate_config_internal(config) do
    errors = []

    # Validate enabled flag
    errors = case get_config_value(config, :enabled) do
      nil -> ["Enabled flag is required" | errors]
      enabled when is_boolean(enabled) -> errors
      _ -> ["Enabled must be a boolean" | errors]
    end

    # Validate max_iterations (1-5)
    errors = case get_config_value(config, :max_iterations) do
      nil -> ["Max iterations is required" | errors]
      iterations when is_integer(iterations) and iterations >= 1 and iterations <= 5 -> errors
      iterations when is_integer(iterations) -> ["Max iterations must be between 1 and 5, got #{iterations}" | errors]
      _ -> ["Max iterations must be an integer between 1 and 5" | errors]
    end

    # Validate quality_threshold (0.0-1.0)
    errors = case get_config_value(config, :quality_threshold) do
      nil -> ["Quality threshold is required" | errors]
      threshold when is_number(threshold) and threshold >= 0.0 and threshold <= 1.0 -> errors
      threshold when is_number(threshold) -> ["Quality threshold must be between 0.0 and 1.0, got #{threshold}" | errors]
      _ -> ["Quality threshold must be a number between 0.0 and 1.0" | errors]
    end

    # Validate timeout_ms
    errors = case get_config_value(config, :timeout_ms) do
      nil -> ["Timeout is required" | errors]
      timeout when is_integer(timeout) and timeout > 0 -> errors
      timeout when is_integer(timeout) -> ["Timeout must be positive, got #{timeout}" | errors]
      _ -> ["Timeout must be a positive integer (milliseconds)" | errors]
    end

    # Validate custom_prompts
    errors = case get_config_value(config, :custom_prompts) do
      nil -> errors  # Optional field
      prompts when is_map(prompts) ->
        validate_custom_prompts(prompts, errors)
      _ -> ["Custom prompts must be a map" | errors]
    end

    # Validate quality_weights
    errors = case get_config_value(config, :quality_weights) do
      nil -> ["Quality weights are required" | errors]
      weights when is_map(weights) ->
        validate_quality_weights(weights, errors)
      _ -> ["Quality weights must be a map" | errors]
    end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_custom_prompts(prompts, errors) do
    required_keys = [:evaluation, :refinement]

    Enum.reduce(required_keys, errors, fn key, acc ->
      case Map.get(prompts, key) do
        nil -> acc  # nil is allowed for custom prompts
        prompt when is_binary(prompt) -> acc
        _ -> ["Custom prompt #{key} must be a string or nil" | acc]
      end
    end)
  end

  defp validate_quality_weights(weights, errors) do
    required_keys = [:completeness, :accuracy, :consistency, :usability]

    # Check all required keys are present
    errors = Enum.reduce(required_keys, errors, fn key, acc ->
      case Map.get(weights, key) do
        nil -> ["Quality weight #{key} is required" | acc]
        weight when is_number(weight) and weight >= 0.0 and weight <= 1.0 -> acc
        weight when is_number(weight) -> ["Quality weight #{key} must be between 0.0 and 1.0, got #{weight}" | acc]
        _ -> ["Quality weight #{key} must be a number between 0.0 and 1.0" | acc]
      end
    end)

    # Check that weights sum to approximately 1.0 (allow small floating point errors)
    case errors do
      [] ->
        total = required_keys
        |> Enum.map(&Map.get(weights, &1, 0.0))
        |> Enum.sum()

        if abs(total - 1.0) > 0.01 do
          ["Quality weights must sum to 1.0, got #{Float.round(total, 3)}" | errors]
        else
          errors
        end
      _ -> errors
    end
  end

  defp get_config_value(config, key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp get_config_file_path() do
    Path.join([Application.app_dir(:decision_engine, "priv"), "reflection_config.json"])
  end

  defp save_config_to_storage(config, file_path) do
    try do
      # Convert to JSON-serializable format (string keys and DateTime to ISO string)
      json_config = config
      |> Enum.map(fn
        {k, %DateTime{} = dt} -> {to_string(k), DateTime.to_iso8601(dt)}
        {k, v} -> {to_string(k), v}
      end)
      |> Map.new()

      storage_data = %{"reflection_config" => json_config}

      # Ensure directory exists
      file_path |> Path.dirname() |> File.mkdir_p!()

      case Jason.encode(storage_data, pretty: true) do
        {:ok, json_string} ->
          case File.write(file_path, json_string) do
            :ok ->
              Logger.debug("Reflection configuration saved to #{file_path}")
              :ok
            {:error, reason} ->
              Logger.error("Failed to write reflection config to file: #{inspect(reason)}")
              {:error, "Failed to save configuration: #{inspect(reason)}"}
          end

        {:error, reason} ->
          Logger.error("Failed to encode reflection config to JSON: #{inspect(reason)}")
          {:error, "Failed to encode configuration: #{inspect(reason)}"}
      end
    rescue
      error ->
        Logger.error("Exception saving reflection config: #{inspect(error)}")
        {:error, "Exception during save: #{inspect(error)}"}
    end
  end

  defp load_config_from_storage(file_path) do
    try do
      case File.read(file_path) do
        {:ok, json_string} ->
          case Jason.decode(json_string) do
            {:ok, %{"reflection_config" => config_data}} ->
              # Convert string keys back to atoms and parse DateTime for internal use
              config = config_data
              |> Enum.map(fn
                {"updated_at", dt_string} when is_binary(dt_string) ->
                  case DateTime.from_iso8601(dt_string) do
                    {:ok, dt, _} -> {:updated_at, dt}
                    _ -> {:updated_at, dt_string}  # Keep as string if parsing fails
                  end
                {"created_at", dt_string} when is_binary(dt_string) ->
                  case DateTime.from_iso8601(dt_string) do
                    {:ok, dt, _} -> {:created_at, dt}
                    _ -> {:created_at, dt_string}
                  end
                {"custom_prompts", prompts} when is_map(prompts) ->
                  # Convert custom_prompts keys to atoms
                  atom_prompts = prompts
                  |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
                  |> Map.new()
                  {:custom_prompts, atom_prompts}
                {"quality_weights", weights} when is_map(weights) ->
                  # Convert quality_weights keys to atoms
                  atom_weights = weights
                  |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
                  |> Map.new()
                  {:quality_weights, atom_weights}
                {k, v} -> {String.to_existing_atom(k), v}
              end)
              |> Map.new()

              # Validate loaded config
              case validate_config_internal(config) do
                :ok ->
                  Logger.debug("Reflection configuration loaded from #{file_path}")
                  {:ok, config}
                {:error, errors} ->
                  Logger.warning("Loaded reflection config is invalid: #{inspect(errors)}")
                  {:error, "Invalid saved configuration: #{Enum.join(errors, ", ")}"}
              end

            {:ok, _} ->
              {:error, "Invalid configuration file format"}

            {:error, reason} ->
              Logger.error("Failed to decode reflection config JSON: #{inspect(reason)}")
              {:error, "Failed to parse configuration file: #{inspect(reason)}"}
          end

        {:error, :enoent} ->
          {:error, "No saved configuration found"}

        {:error, reason} ->
          Logger.error("Failed to read reflection config file: #{inspect(reason)}")
          {:error, "Failed to read configuration file: #{inspect(reason)}"}
      end
    rescue
      ArgumentError ->
        # This happens when trying to convert unknown string to existing atom
        Logger.warning("Reflection config contains unknown keys, using defaults")
        {:error, "Configuration contains unknown keys"}

      error ->
        Logger.error("Exception loading reflection config: #{inspect(error)}")
        {:error, "Exception during load: #{inspect(error)}"}
    end
  end
end
