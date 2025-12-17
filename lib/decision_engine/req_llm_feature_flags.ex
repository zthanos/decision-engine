# lib/decision_engine/req_llm_feature_flags.ex
defmodule DecisionEngine.ReqLLMFeatureFlags do
  @moduledoc """
  Feature flag system for controlling the gradual migration to ReqLLM.

  This module provides feature flags to control the rollout of ReqLLM integration,
  allowing for gradual migration with fallback mechanisms to the legacy implementation.
  """

  use GenServer
  require Logger

  @default_flags %{
    # Core ReqLLM integration flags
    reqllm_enabled: false,
    reqllm_streaming_enabled: false,
    reqllm_non_streaming_enabled: false,

    # Provider-specific flags
    reqllm_openai_enabled: false,
    reqllm_anthropic_enabled: false,
    reqllm_ollama_enabled: false,
    reqllm_openrouter_enabled: false,
    reqllm_custom_enabled: false,

    # Feature-specific flags
    reqllm_connection_pooling_enabled: false,
    reqllm_retry_logic_enabled: false,
    reqllm_circuit_breaker_enabled: false,
    reqllm_rate_limiting_enabled: false,

    # Migration control flags
    migration_phase: :not_started,  # :not_started, :phase_1, :phase_2, :phase_3, :completed
    fallback_enabled: true,
    legacy_monitoring_enabled: true,

    # Rollout percentage (0-100)
    rollout_percentage: 0,

    # Environment-specific overrides
    force_legacy: false,
    force_reqllm: false
  }

  @migration_phases %{
    not_started: "Migration not started - using legacy implementation",
    phase_1: "Phase 1: Basic ReqLLM integration for non-streaming requests",
    phase_2: "Phase 2: ReqLLM streaming and enhanced error handling",
    phase_3: "Phase 3: Advanced ReqLLM features (connection pooling, circuit breaker)",
    completed: "Migration completed - fully using ReqLLM"
  }

  # Client API

  @doc """
  Starts the ReqLLM Feature Flags GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if ReqLLM is enabled for the given context.

  ## Parameters
  - context: Map containing request context (provider, operation_type, etc.)

  ## Returns
  - true if ReqLLM should be used
  - false if legacy implementation should be used
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(context \\ %{}) do
    GenServer.call(__MODULE__, {:enabled?, context})
  end

  @doc """
  Checks if a specific ReqLLM feature is enabled.

  ## Parameters
  - feature: Atom representing the feature flag

  ## Returns
  - true if feature is enabled
  - false if feature is disabled
  """
  @spec feature_enabled?(atom()) :: boolean()
  def feature_enabled?(feature) do
    GenServer.call(__MODULE__, {:feature_enabled?, feature})
  end

  @doc """
  Sets a feature flag value.

  ## Parameters
  - flag: Atom representing the feature flag
  - value: Boolean or other value to set

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec set_flag(atom(), term()) :: :ok | {:error, term()}
  def set_flag(flag, value) do
    GenServer.call(__MODULE__, {:set_flag, flag, value})
  end

  @doc """
  Gets the current value of a feature flag.

  ## Parameters
  - flag: Atom representing the feature flag

  ## Returns
  - {:ok, value} if flag exists
  - {:error, :not_found} if flag doesn't exist
  """
  @spec get_flag(atom()) :: {:ok, term()} | {:error, :not_found}
  def get_flag(flag) do
    GenServer.call(__MODULE__, {:get_flag, flag})
  end

  @doc """
  Gets all current feature flags.

  ## Returns
  - Map of all feature flags and their values
  """
  @spec get_all_flags() :: map()
  def get_all_flags() do
    GenServer.call(__MODULE__, :get_all_flags)
  end

  @doc """
  Sets the migration phase.

  ## Parameters
  - phase: Atom representing the migration phase

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec set_migration_phase(atom()) :: :ok | {:error, term()}
  def set_migration_phase(phase) do
    GenServer.call(__MODULE__, {:set_migration_phase, phase})
  end

  @doc """
  Gets the current migration phase.

  ## Returns
  - {:ok, {phase, description}} with current phase and description
  """
  @spec get_migration_phase() :: {:ok, {atom(), String.t()}}
  def get_migration_phase() do
    GenServer.call(__MODULE__, :get_migration_phase)
  end

  @doc """
  Sets the rollout percentage for gradual rollout.

  ## Parameters
  - percentage: Integer between 0 and 100

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec set_rollout_percentage(integer()) :: :ok | {:error, term()}
  def set_rollout_percentage(percentage) do
    GenServer.call(__MODULE__, {:set_rollout_percentage, percentage})
  end

  @doc """
  Checks if the current request should use ReqLLM based on rollout percentage.

  ## Parameters
  - identifier: String identifier for consistent rollout (e.g., session_id, user_id)

  ## Returns
  - true if request should use ReqLLM
  - false if request should use legacy implementation
  """
  @spec in_rollout?(String.t()) :: boolean()
  def in_rollout?(identifier) do
    GenServer.call(__MODULE__, {:in_rollout?, identifier})
  end

  @doc """
  Enables fallback to legacy implementation.
  """
  @spec enable_fallback() :: :ok
  def enable_fallback() do
    GenServer.call(__MODULE__, :enable_fallback)
  end

  @doc """
  Disables fallback to legacy implementation.
  """
  @spec disable_fallback() :: :ok
  def disable_fallback() do
    GenServer.call(__MODULE__, :disable_fallback)
  end

  @doc """
  Checks if fallback to legacy implementation is enabled.
  """
  @spec fallback_enabled?() :: boolean()
  def fallback_enabled?() do
    GenServer.call(__MODULE__, :fallback_enabled?)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Feature Flags system")

    # Load flags from application config or use defaults
    flags = load_flags_from_config()

    state = %{
      flags: flags,
      rollout_cache: %{}  # Cache for rollout decisions
    }

    Logger.info("ReqLLM Feature Flags initialized with phase: #{flags.migration_phase}")
    {:ok, state}
  end

  @impl true
  def handle_call({:enabled?, context}, _from, state) do
    result = determine_reqllm_enabled(context, state.flags)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:feature_enabled?, feature}, _from, state) do
    result = Map.get(state.flags, feature, false)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_flag, flag, value}, _from, state) do
    case validate_flag_value(flag, value) do
      :ok ->
        new_flags = Map.put(state.flags, flag, value)
        new_state = %{state | flags: new_flags}

        # Persist flags to config
        persist_flags_to_config(new_flags)

        Logger.info("Feature flag #{flag} set to #{inspect(value)}")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_flag, flag}, _from, state) do
    case Map.get(state.flags, flag) do
      nil -> {:reply, {:error, :not_found}, state}
      value -> {:reply, {:ok, value}, state}
    end
  end

  @impl true
  def handle_call(:get_all_flags, _from, state) do
    {:reply, state.flags, state}
  end

  @impl true
  def handle_call({:set_migration_phase, phase}, _from, state) do
    case validate_migration_phase(phase) do
      :ok ->
        new_flags = update_flags_for_phase(state.flags, phase)
        new_state = %{state | flags: new_flags}

        # Persist flags to config
        persist_flags_to_config(new_flags)

        Logger.info("Migration phase set to #{phase}: #{@migration_phases[phase]}")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_migration_phase, _from, state) do
    phase = state.flags.migration_phase
    description = @migration_phases[phase]
    {:reply, {:ok, {phase, description}}, state}
  end

  @impl true
  def handle_call({:set_rollout_percentage, percentage}, _from, state) do
    case validate_rollout_percentage(percentage) do
      :ok ->
        new_flags = Map.put(state.flags, :rollout_percentage, percentage)
        new_state = %{state | flags: new_flags, rollout_cache: %{}}  # Clear cache

        # Persist flags to config
        persist_flags_to_config(new_flags)

        Logger.info("Rollout percentage set to #{percentage}%")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:in_rollout?, identifier}, _from, state) do
    # Check cache first
    case Map.get(state.rollout_cache, identifier) do
      nil ->
        # Calculate rollout decision
        result = calculate_rollout_decision(identifier, state.flags.rollout_percentage)

        # Cache the decision
        new_cache = Map.put(state.rollout_cache, identifier, result)
        new_state = %{state | rollout_cache: new_cache}

        {:reply, result, new_state}

      cached_result ->
        {:reply, cached_result, state}
    end
  end

  @impl true
  def handle_call(:enable_fallback, _from, state) do
    new_flags = Map.put(state.flags, :fallback_enabled, true)
    new_state = %{state | flags: new_flags}

    persist_flags_to_config(new_flags)
    Logger.info("Fallback to legacy implementation enabled")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:disable_fallback, _from, state) do
    new_flags = Map.put(state.flags, :fallback_enabled, false)
    new_state = %{state | flags: new_flags}

    persist_flags_to_config(new_flags)
    Logger.info("Fallback to legacy implementation disabled")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:fallback_enabled?, _from, state) do
    result = Map.get(state.flags, :fallback_enabled, true)
    {:reply, result, state}
  end

  # Private Functions

  defp determine_reqllm_enabled(context, flags) do
    # Check force flags first
    cond do
      flags.force_legacy -> false
      flags.force_reqllm -> true
      not flags.reqllm_enabled -> false
      true -> check_context_specific_flags(context, flags)
    end
  end

  defp check_context_specific_flags(context, flags) do
    provider = Map.get(context, :provider, :openai)
    operation_type = Map.get(context, :operation_type, :non_streaming)

    # Check provider-specific flags
    provider_enabled = case provider do
      :openai -> flags.reqllm_openai_enabled
      :anthropic -> flags.reqllm_anthropic_enabled
      :ollama -> flags.reqllm_ollama_enabled
      :openrouter -> flags.reqllm_openrouter_enabled
      :custom -> flags.reqllm_custom_enabled
      _ -> false
    end

    # Check operation-specific flags
    operation_enabled = case operation_type do
      :streaming -> flags.reqllm_streaming_enabled
      :non_streaming -> flags.reqllm_non_streaming_enabled
      _ -> false
    end

    provider_enabled and operation_enabled
  end

  defp validate_flag_value(flag, value) do
    case flag do
      flag when flag in [:reqllm_enabled, :reqllm_streaming_enabled, :reqllm_non_streaming_enabled,
                         :reqllm_openai_enabled, :reqllm_anthropic_enabled, :reqllm_ollama_enabled,
                         :reqllm_openrouter_enabled, :reqllm_custom_enabled, :reqllm_connection_pooling_enabled,
                         :reqllm_retry_logic_enabled, :reqllm_circuit_breaker_enabled, :reqllm_rate_limiting_enabled,
                         :fallback_enabled, :legacy_monitoring_enabled, :force_legacy, :force_reqllm] ->
        if is_boolean(value) do
          :ok
        else
          {:error, "#{flag} must be a boolean"}
        end

      :migration_phase ->
        validate_migration_phase(value)

      :rollout_percentage ->
        validate_rollout_percentage(value)

      _ ->
        {:error, "Unknown flag: #{flag}"}
    end
  end

  defp validate_migration_phase(phase) do
    if phase in Map.keys(@migration_phases) do
      :ok
    else
      valid_phases = Map.keys(@migration_phases) |> Enum.join(", ")
      {:error, "Invalid migration phase: #{phase}. Valid phases: #{valid_phases}"}
    end
  end

  defp validate_rollout_percentage(percentage) do
    if is_integer(percentage) and percentage >= 0 and percentage <= 100 do
      :ok
    else
      {:error, "Rollout percentage must be an integer between 0 and 100"}
    end
  end

  defp update_flags_for_phase(flags, phase) do
    case phase do
      :not_started ->
        flags
        |> Map.put(:migration_phase, :not_started)
        |> Map.put(:reqllm_enabled, false)
        |> Map.put(:fallback_enabled, true)

      :phase_1 ->
        flags
        |> Map.put(:migration_phase, :phase_1)
        |> Map.put(:reqllm_enabled, true)
        |> Map.put(:reqllm_non_streaming_enabled, true)
        |> Map.put(:reqllm_streaming_enabled, false)
        |> Map.put(:fallback_enabled, true)

      :phase_2 ->
        flags
        |> Map.put(:migration_phase, :phase_2)
        |> Map.put(:reqllm_enabled, true)
        |> Map.put(:reqllm_non_streaming_enabled, true)
        |> Map.put(:reqllm_streaming_enabled, true)
        |> Map.put(:reqllm_retry_logic_enabled, true)
        |> Map.put(:fallback_enabled, true)

      :phase_3 ->
        flags
        |> Map.put(:migration_phase, :phase_3)
        |> Map.put(:reqllm_enabled, true)
        |> Map.put(:reqllm_non_streaming_enabled, true)
        |> Map.put(:reqllm_streaming_enabled, true)
        |> Map.put(:reqllm_retry_logic_enabled, true)
        |> Map.put(:reqllm_connection_pooling_enabled, true)
        |> Map.put(:reqllm_circuit_breaker_enabled, true)
        |> Map.put(:reqllm_rate_limiting_enabled, true)
        |> Map.put(:fallback_enabled, true)

      :completed ->
        flags
        |> Map.put(:migration_phase, :completed)
        |> Map.put(:reqllm_enabled, true)
        |> Map.put(:reqllm_non_streaming_enabled, true)
        |> Map.put(:reqllm_streaming_enabled, true)
        |> Map.put(:reqllm_retry_logic_enabled, true)
        |> Map.put(:reqllm_connection_pooling_enabled, true)
        |> Map.put(:reqllm_circuit_breaker_enabled, true)
        |> Map.put(:reqllm_rate_limiting_enabled, true)
        |> Map.put(:fallback_enabled, false)
    end
  end

  defp calculate_rollout_decision(identifier, percentage) do
    # Use consistent hash-based rollout
    hash = :erlang.phash2(identifier, 100)
    hash < percentage
  end

  defp load_flags_from_config() do
    case Application.get_env(:decision_engine, :req_llm_feature_flags) do
      nil ->
        Logger.info("No ReqLLM feature flags found in config, using defaults")
        @default_flags

      config_flags ->
        Logger.info("Loading ReqLLM feature flags from application config")
        Map.merge(@default_flags, config_flags)
    end
  end

  defp persist_flags_to_config(flags) do
    # Store flags in application environment
    Application.put_env(:decision_engine, :req_llm_feature_flags, flags)

    # In a production system, you might want to persist to a database or file
    # For now, we'll just store in application environment
    :ok
  end
end
