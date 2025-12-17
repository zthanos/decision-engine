# lib/decision_engine/req_llm_runtime_config.ex
defmodule DecisionEngine.ReqLLMRuntimeConfig do
  @moduledoc """
  Runtime configuration management for ReqLLM integration.

  This module provides hot-reloading of provider configurations, runtime model
  and parameter switching, and configuration validation with rollback capabilities.
  Supports requirement 8.2 for runtime configuration changes.
  """

  use GenServer
  require Logger
  alias DecisionEngine.ReqLLMConfigManager

  @config_backup_limit 10
  @validation_timeout 5000

  defstruct [
    :current_config,
    :config_history,
    :active_providers,
    :validation_cache,
    :hot_reload_enabled,
    :rollback_enabled
  ]

  # Client API

  @doc """
  Starts the Runtime Configuration Manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Hot-reloads provider configuration without application restart.

  ## Parameters
  - provider: Atom representing the provider
  - new_config: Map containing new configuration

  ## Returns
  - {:ok, config} if reload successful
  - {:error, reason} if reload fails
  """
  @spec hot_reload_provider(atom(), map()) :: {:ok, map()} | {:error, term()}
  def hot_reload_provider(provider, new_config) do
    GenServer.call(__MODULE__, {:hot_reload_provider, provider, new_config}, @validation_timeout)
  end

  @doc """
  Switches model and parameters at runtime.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the new model
  - params: Map containing new parameters (optional)

  ## Returns
  - {:ok, updated_config} if switch successful
  - {:error, reason} if switch fails
  """
  @spec switch_model_runtime(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def switch_model_runtime(provider, model, params \\ %{}) do
    GenServer.call(__MODULE__, {:switch_model_runtime, provider, model, params}, @validation_timeout)
  end

  @doc """
  Updates provider parameters at runtime.

  ## Parameters
  - provider: Atom representing the provider
  - updates: Map containing parameter updates

  ## Returns
  - {:ok, updated_config} if update successful
  - {:error, reason} if update fails
  """
  @spec update_runtime_params(atom(), map()) :: {:ok, map()} | {:error, term()}
  def update_runtime_params(provider, updates) do
    GenServer.call(__MODULE__, {:update_runtime_params, provider, updates})
  end

  @doc """
  Validates configuration changes before applying them.

  ## Parameters
  - provider: Atom representing the provider
  - config: Map containing configuration to validate

  ## Returns
  - {:ok, validated_config} if validation passes
  - {:error, validation_errors} if validation fails
  """
  @spec validate_config_change(atom(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_config_change(provider, config) do
    GenServer.call(__MODULE__, {:validate_config_change, provider, config})
  end

  @doc """
  Rolls back to previous configuration.

  ## Parameters
  - provider: Atom representing the provider
  - steps_back: Integer number of steps to roll back (default: 1)

  ## Returns
  - {:ok, rolled_back_config} if rollback successful
  - {:error, reason} if rollback fails
  """
  @spec rollback_config(atom(), integer()) :: {:ok, map()} | {:error, term()}
  def rollback_config(provider, steps_back \\ 1) do
    GenServer.call(__MODULE__, {:rollback_config, provider, steps_back})
  end

  @doc """
  Gets current configuration for a provider.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, config} if provider configured
  - {:error, reason} if provider not found
  """
  @spec get_current_config(atom()) :: {:ok, map()} | {:error, term()}
  def get_current_config(provider) do
    GenServer.call(__MODULE__, {:get_current_config, provider})
  end

  @doc """
  Gets configuration history for a provider.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, history} with list of historical configurations
  - {:error, reason} if provider not found
  """
  @spec get_config_history(atom()) :: {:ok, [map()]} | {:error, term()}
  def get_config_history(provider) do
    GenServer.call(__MODULE__, {:get_config_history, provider})
  end

  @doc """
  Lists all active providers with their current configurations.

  ## Returns
  - Map with provider atoms as keys and configurations as values
  """
  @spec list_active_providers() :: map()
  def list_active_providers do
    GenServer.call(__MODULE__, :list_active_providers)
  end

  @doc """
  Enables or disables hot-reloading capability.

  ## Parameters
  - enabled: Boolean to enable/disable hot-reloading

  ## Returns
  - :ok
  """
  @spec set_hot_reload_enabled(boolean()) :: :ok
  def set_hot_reload_enabled(enabled) do
    GenServer.cast(__MODULE__, {:set_hot_reload_enabled, enabled})
  end

  @doc """
  Enables or disables rollback capability.

  ## Parameters
  - enabled: Boolean to enable/disable rollback

  ## Returns
  - :ok
  """
  @spec set_rollback_enabled(boolean()) :: :ok
  def set_rollback_enabled(enabled) do
    GenServer.cast(__MODULE__, {:set_rollback_enabled, enabled})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Runtime Configuration Manager")

    state = %__MODULE__{
      current_config: %{},
      config_history: %{},
      active_providers: MapSet.new(),
      validation_cache: %{},
      hot_reload_enabled: true,
      rollback_enabled: true
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:hot_reload_provider, provider, new_config}, _from, state) do
    if state.hot_reload_enabled do
      case perform_hot_reload(provider, new_config, state) do
        {:ok, updated_state} ->
          Logger.info("Successfully hot-reloaded configuration for provider #{provider}")
          {:reply, {:ok, Map.get(updated_state.current_config, provider)}, updated_state}

        {:error, reason} ->
          Logger.error("Hot-reload failed for provider #{provider}: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Hot-reloading is disabled"}, state}
    end
  end

  @impl true
  def handle_call({:switch_model_runtime, provider, model, params}, _from, state) do
    case Map.get(state.current_config, provider) do
      nil ->
        {:reply, {:error, "Provider #{provider} not configured"}, state}

      current_config ->
        # Create updated configuration with new model and parameters
        updates = Map.merge(%{model: model}, params)
        updated_config = Map.merge(current_config, updates)

        case validate_and_apply_config(provider, updated_config, state) do
          {:ok, updated_state} ->
            Logger.info("Successfully switched model for provider #{provider} to #{model}")
            {:reply, {:ok, updated_config}, updated_state}

          {:error, reason} ->
            Logger.error("Model switch failed for provider #{provider}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:update_runtime_params, provider, updates}, _from, state) do
    case Map.get(state.current_config, provider) do
      nil ->
        {:reply, {:error, "Provider #{provider} not configured"}, state}

      current_config ->
        updated_config = Map.merge(current_config, updates)

        case validate_and_apply_config(provider, updated_config, state) do
          {:ok, updated_state} ->
            Logger.info("Successfully updated runtime parameters for provider #{provider}")
            {:reply, {:ok, updated_config}, updated_state}

          {:error, reason} ->
            Logger.error("Runtime parameter update failed for provider #{provider}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:validate_config_change, provider, config}, _from, state) do
    # Check validation cache first
    cache_key = {provider, :erlang.phash2(config)}
    case Map.get(state.validation_cache, cache_key) do
      nil ->
        # Perform validation
        case ReqLLMConfigManager.validate_reqllm_config(config) do
          :ok ->
            # Cache successful validation
            updated_cache = Map.put(state.validation_cache, cache_key, {:ok, config})
            updated_state = %{state | validation_cache: updated_cache}
            {:reply, {:ok, config}, updated_state}

          {:error, errors} ->
            # Cache validation errors
            updated_cache = Map.put(state.validation_cache, cache_key, {:error, errors})
            updated_state = %{state | validation_cache: updated_cache}
            {:reply, {:error, errors}, updated_state}
        end

      cached_result ->
        {:reply, cached_result, state}
    end
  end

  @impl true
  def handle_call({:rollback_config, provider, steps_back}, _from, state) do
    if state.rollback_enabled do
      case perform_rollback(provider, steps_back, state) do
        {:ok, rolled_back_config, updated_state} ->
          Logger.info("Successfully rolled back configuration for provider #{provider} by #{steps_back} steps")
          {:reply, {:ok, rolled_back_config}, updated_state}

        {:error, reason} ->
          Logger.error("Rollback failed for provider #{provider}: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Rollback is disabled"}, state}
    end
  end

  @impl true
  def handle_call({:get_current_config, provider}, _from, state) do
    case Map.get(state.current_config, provider) do
      nil ->
        {:reply, {:error, "Provider #{provider} not configured"}, state}
      config ->
        {:reply, {:ok, config}, state}
    end
  end

  @impl true
  def handle_call({:get_config_history, provider}, _from, state) do
    history = Map.get(state.config_history, provider, [])
    {:reply, {:ok, history}, state}
  end

  @impl true
  def handle_call(:list_active_providers, _from, state) do
    {:reply, state.current_config, state}
  end

  @impl true
  def handle_cast({:set_hot_reload_enabled, enabled}, state) do
    Logger.info("Hot-reload #{if enabled, do: "enabled", else: "disabled"}")
    {:noreply, %{state | hot_reload_enabled: enabled}}
  end

  @impl true
  def handle_cast({:set_rollback_enabled, enabled}, state) do
    Logger.info("Rollback #{if enabled, do: "enabled", else: "disabled"}")
    {:noreply, %{state | rollback_enabled: enabled}}
  end

  # Private Functions

  defp perform_hot_reload(provider, new_config, state) do
    # Validate new configuration first
    case ReqLLMConfigManager.validate_reqllm_config(new_config) do
      :ok ->
        # Backup current configuration if it exists
        updated_state = backup_current_config(provider, state)

        # Apply new configuration
        updated_current_config = Map.put(updated_state.current_config, provider, new_config)
        updated_active_providers = MapSet.put(updated_state.active_providers, provider)

        final_state = %{updated_state |
          current_config: updated_current_config,
          active_providers: updated_active_providers
        }

        # Notify ReqLLMConfigManager of the configuration change
        case ReqLLMConfigManager.update_provider_settings(provider, new_config) do
          {:ok, _} ->
            {:ok, final_state}
          {:error, reason} ->
            {:error, "Failed to apply configuration to ReqLLMConfigManager: #{reason}"}
        end

      {:error, errors} ->
        {:error, "Configuration validation failed: #{Enum.join(errors, ", ")}"}
    end
  end

  defp validate_and_apply_config(provider, config, state) do
    case ReqLLMConfigManager.validate_reqllm_config(config) do
      :ok ->
        # Backup current configuration
        updated_state = backup_current_config(provider, state)

        # Apply new configuration
        updated_current_config = Map.put(updated_state.current_config, provider, config)
        updated_active_providers = MapSet.put(updated_state.active_providers, provider)

        final_state = %{updated_state |
          current_config: updated_current_config,
          active_providers: updated_active_providers
        }

        # Notify ReqLLMConfigManager of the configuration change
        case ReqLLMConfigManager.update_provider_settings(provider, config) do
          {:ok, _} ->
            {:ok, final_state}
          {:error, reason} ->
            {:error, "Failed to apply configuration to ReqLLMConfigManager: #{reason}"}
        end

      {:error, errors} ->
        {:error, "Configuration validation failed: #{Enum.join(errors, ", ")}"}
    end
  end

  defp backup_current_config(provider, state) do
    case Map.get(state.current_config, provider) do
      nil ->
        state  # No current config to backup

      current_config ->
        # Add timestamp to the backup
        timestamped_config = Map.put(current_config, :backup_timestamp, System.system_time(:millisecond))

        # Get current history and add new backup
        current_history = Map.get(state.config_history, provider, [])
        updated_history = [timestamped_config | current_history]
        |> Enum.take(@config_backup_limit)  # Limit history size

        # Update state with new history
        updated_config_history = Map.put(state.config_history, provider, updated_history)
        %{state | config_history: updated_config_history}
    end
  end

  defp perform_rollback(provider, steps_back, state) do
    case Map.get(state.config_history, provider) do
      nil ->
        {:error, "No configuration history available for provider #{provider}"}

      [] ->
        {:error, "No configuration history available for provider #{provider}"}

      history when length(history) < steps_back ->
        {:error, "Not enough configuration history (requested #{steps_back}, available #{length(history)})"}

      history ->
        # Get the configuration to roll back to
        rolled_back_config = Enum.at(history, steps_back - 1)
        |> Map.delete(:backup_timestamp)  # Remove backup metadata

        # Validate the rolled back configuration
        case ReqLLMConfigManager.validate_reqllm_config(rolled_back_config) do
          :ok ->
            # Update current configuration
            updated_current_config = Map.put(state.current_config, provider, rolled_back_config)

            # Remove rolled back configurations from history
            updated_history = Enum.drop(history, steps_back)
            updated_config_history = Map.put(state.config_history, provider, updated_history)

            updated_state = %{state |
              current_config: updated_current_config,
              config_history: updated_config_history
            }

            # Notify ReqLLMConfigManager of the rollback
            case ReqLLMConfigManager.update_provider_settings(provider, rolled_back_config) do
              {:ok, _} ->
                {:ok, rolled_back_config, updated_state}
              {:error, reason} ->
                {:error, "Failed to apply rolled back configuration: #{reason}"}
            end

          {:error, errors} ->
            {:error, "Rolled back configuration is invalid: #{Enum.join(errors, ", ")}"}
        end
    end
  end
end
