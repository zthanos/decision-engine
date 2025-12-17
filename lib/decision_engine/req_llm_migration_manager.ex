# lib/decision_engine/req_llm_migration_manager.ex
defmodule DecisionEngine.ReqLLMMigrationManager do
  @moduledoc """
  Manages the phased migration rollout from legacy LLM implementation to ReqLLM.

  This module orchestrates the gradual migration process, starting with low-risk
  non-streaming requests and gradually enabling streaming and advanced features.
  """

  use GenServer
  require Logger

  alias DecisionEngine.ReqLLMFeatureFlags
  alias DecisionEngine.ReqLLMPerformanceMonitor

  @migration_schedule %{
    phase_1: %{
      name: "Basic ReqLLM Integration",
      description: "Enable ReqLLM for non-streaming requests only",
      rollout_percentage: 10,
      duration_hours: 24,
      success_criteria: %{
        error_rate_threshold: 0.05,
        latency_increase_threshold: 1.2,
        min_requests: 100
      }
    },
    phase_2: %{
      name: "Streaming Integration",
      description: "Enable ReqLLM streaming with enhanced error handling",
      rollout_percentage: 25,
      duration_hours: 48,
      success_criteria: %{
        error_rate_threshold: 0.03,
        latency_increase_threshold: 1.1,
        streaming_success_rate: 0.95,
        min_requests: 500
      }
    },
    phase_3: %{
      name: "Advanced Features",
      description: "Enable connection pooling, circuit breaker, and rate limiting",
      rollout_percentage: 50,
      duration_hours: 72,
      success_criteria: %{
        error_rate_threshold: 0.02,
        latency_decrease_threshold: 0.9,
        connection_pool_efficiency: 0.8,
        min_requests: 1000
      }
    },
    completed: %{
      name: "Full Migration",
      description: "Complete migration to ReqLLM with legacy cleanup",
      rollout_percentage: 100,
      duration_hours: 168,
      success_criteria: %{
        error_rate_threshold: 0.01,
        performance_improvement: 1.3,
        min_requests: 5000
      }
    }
  }

  # Client API

  @doc """
  Starts the migration manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts the phased migration rollout.
  """
  @spec start_migration() :: :ok | {:error, term()}
  def start_migration() do
    GenServer.call(__MODULE__, :start_migration)
  end

  @doc """
  Advances to the next migration phase if criteria are met.
  """
  @spec advance_phase() :: :ok | {:error, term()}
  def advance_phase() do
    GenServer.call(__MODULE__, :advance_phase)
  end

  @doc """
  Rolls back to the previous migration phase.
  """
  @spec rollback_phase() :: :ok | {:error, term()}
  def rollback_phase() do
    GenServer.call(__MODULE__, :rollback_phase)
  end

  @doc """
  Gets the current migration status.
  """
  @spec get_migration_status() :: map()
  def get_migration_status() do
    GenServer.call(__MODULE__, :get_migration_status)
  end

  @doc """
  Forces migration to a specific phase (for testing/emergency).
  """
  @spec force_phase(atom()) :: :ok | {:error, term()}
  def force_phase(phase) do
    GenServer.call(__MODULE__, {:force_phase, phase})
  end

  @doc """
  Enables automatic phase advancement based on success criteria.
  """
  @spec enable_auto_advance() :: :ok
  def enable_auto_advance() do
    GenServer.call(__MODULE__, :enable_auto_advance)
  end

  @doc """
  Disables automatic phase advancement.
  """
  @spec disable_auto_advance() :: :ok
  def disable_auto_advance() do
    GenServer.call(__MODULE__, :disable_auto_advance)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Migration Manager")

    # Get current migration phase from feature flags
    {:ok, {current_phase, _description}} = ReqLLMFeatureFlags.get_migration_phase()

    state = %{
      current_phase: current_phase,
      phase_start_time: nil,
      auto_advance_enabled: false,
      migration_metrics: %{},
      rollback_history: []
    }

    # Schedule periodic health checks
    schedule_health_check()

    Logger.info("Migration Manager initialized with phase: #{current_phase}")
    {:ok, state}
  end

  @impl true
  def handle_call(:start_migration, _from, state) do
    case state.current_phase do
      :not_started ->
        Logger.info("Starting migration from phase :not_started to :phase_1")

        case transition_to_phase(:phase_1, state) do
          {:ok, new_state} ->
            {:reply, :ok, new_state}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      phase ->
        Logger.warning("Migration already started, currently in phase: #{phase}")
        {:reply, {:error, "Migration already in progress at phase #{phase}"}, state}
    end
  end

  @impl true
  def handle_call(:advance_phase, _from, state) do
    next_phase = get_next_phase(state.current_phase)

    case next_phase do
      nil ->
        {:reply, {:error, "Already at final phase"}, state}

      phase ->
        case check_advancement_criteria(state) do
          :ok ->
            case transition_to_phase(phase, state) do
              {:ok, new_state} ->
                {:reply, :ok, new_state}
              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            Logger.warning("Cannot advance phase: #{reason}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:rollback_phase, _from, state) do
    previous_phase = get_previous_phase(state.current_phase)

    case previous_phase do
      nil ->
        {:reply, {:error, "Already at initial phase"}, state}

      phase ->
        Logger.warning("Rolling back from #{state.current_phase} to #{phase}")

        case transition_to_phase(phase, state) do
          {:ok, new_state} ->
            # Record rollback in history
            rollback_entry = %{
              from_phase: state.current_phase,
              to_phase: phase,
              timestamp: System.system_time(:second),
              reason: "Manual rollback"
            }

            updated_state = %{new_state |
              rollback_history: [rollback_entry | state.rollback_history]
            }

            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_migration_status, _from, state) do
    {:ok, {current_phase, description}} = ReqLLMFeatureFlags.get_migration_phase()

    phase_config = Map.get(@migration_schedule, current_phase, %{})

    status = %{
      current_phase: current_phase,
      phase_description: description,
      phase_config: phase_config,
      phase_start_time: state.phase_start_time,
      auto_advance_enabled: state.auto_advance_enabled,
      migration_metrics: state.migration_metrics,
      rollback_history: state.rollback_history,
      next_phase: get_next_phase(current_phase),
      can_advance: check_advancement_criteria(state) == :ok
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:force_phase, phase}, _from, state) do
    Logger.warning("Force transitioning to phase: #{phase}")

    case transition_to_phase(phase, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:enable_auto_advance, _from, state) do
    Logger.info("Enabling automatic phase advancement")
    new_state = %{state | auto_advance_enabled: true}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:disable_auto_advance, _from, state) do
    Logger.info("Disabling automatic phase advancement")
    new_state = %{state | auto_advance_enabled: false}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Perform health check and auto-advance if enabled
    new_state = perform_health_check(state)

    # Schedule next health check
    schedule_health_check()

    {:noreply, new_state}
  end

  # Private Functions

  defp transition_to_phase(phase, state) do
    Logger.info("Transitioning to migration phase: #{phase}")

    case ReqLLMFeatureFlags.set_migration_phase(phase) do
      :ok ->
        # Update rollout percentage for the new phase
        phase_config = Map.get(@migration_schedule, phase, %{})
        rollout_percentage = Map.get(phase_config, :rollout_percentage, 0)

        case ReqLLMFeatureFlags.set_rollout_percentage(rollout_percentage) do
          :ok ->
            new_state = %{state |
              current_phase: phase,
              phase_start_time: System.system_time(:second),
              migration_metrics: %{}
            }

            Logger.info("Successfully transitioned to phase #{phase} with #{rollout_percentage}% rollout")
            {:ok, new_state}

          {:error, reason} ->
            Logger.error("Failed to set rollout percentage: #{inspect(reason)}")
            {:error, "Failed to set rollout percentage: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("Failed to set migration phase: #{inspect(reason)}")
        {:error, "Failed to set migration phase: #{inspect(reason)}"}
    end
  end

  defp get_next_phase(:not_started), do: :phase_1
  defp get_next_phase(:phase_1), do: :phase_2
  defp get_next_phase(:phase_2), do: :phase_3
  defp get_next_phase(:phase_3), do: :completed
  defp get_next_phase(:completed), do: nil

  defp get_previous_phase(:phase_1), do: :not_started
  defp get_previous_phase(:phase_2), do: :phase_1
  defp get_previous_phase(:phase_3), do: :phase_2
  defp get_previous_phase(:completed), do: :phase_3
  defp get_previous_phase(:not_started), do: nil

  defp check_advancement_criteria(state) do
    phase_config = Map.get(@migration_schedule, state.current_phase, %{})
    success_criteria = Map.get(phase_config, :success_criteria, %{})

    if Enum.empty?(success_criteria) do
      :ok
    else
      # Get current metrics from performance monitor
      case ReqLLMPerformanceMonitor.get_current_metrics() do
        {:ok, metrics} ->
          validate_success_criteria(success_criteria, metrics, state)

        {:error, reason} ->
          Logger.warning("Cannot get performance metrics: #{inspect(reason)}")
          {:error, "Performance metrics unavailable"}
      end
    end
  end

  defp validate_success_criteria(criteria, metrics, state) do
    # Check if phase has been running long enough
    phase_config = Map.get(@migration_schedule, state.current_phase, %{})
    min_duration_hours = Map.get(phase_config, :duration_hours, 24)

    if state.phase_start_time do
      hours_elapsed = (System.system_time(:second) - state.phase_start_time) / 3600

      if hours_elapsed < min_duration_hours do
        {:error, "Phase duration not met (#{trunc(hours_elapsed)}/#{min_duration_hours} hours)"}
      else
        validate_metrics_criteria(criteria, metrics)
      end
    else
      {:error, "Phase start time not recorded"}
    end
  end

  defp validate_metrics_criteria(criteria, metrics) do
    results = Enum.map(criteria, fn {criterion, threshold} ->
      case criterion do
        :error_rate_threshold ->
          current_error_rate = Map.get(metrics, :error_rate, 1.0)
          if current_error_rate <= threshold do
            :ok
          else
            {:error, "Error rate too high: #{current_error_rate} > #{threshold}"}
          end

        :latency_increase_threshold ->
          current_latency_ratio = Map.get(metrics, :latency_ratio, 2.0)
          if current_latency_ratio <= threshold do
            :ok
          else
            {:error, "Latency increase too high: #{current_latency_ratio} > #{threshold}"}
          end

        :latency_decrease_threshold ->
          current_latency_ratio = Map.get(metrics, :latency_ratio, 2.0)
          if current_latency_ratio <= threshold do
            :ok
          else
            {:error, "Latency not improved enough: #{current_latency_ratio} > #{threshold}"}
          end

        :streaming_success_rate ->
          current_streaming_rate = Map.get(metrics, :streaming_success_rate, 0.0)
          if current_streaming_rate >= threshold do
            :ok
          else
            {:error, "Streaming success rate too low: #{current_streaming_rate} < #{threshold}"}
          end

        :min_requests ->
          current_requests = Map.get(metrics, :total_requests, 0)
          if current_requests >= threshold do
            :ok
          else
            {:error, "Not enough requests processed: #{current_requests} < #{threshold}"}
          end

        :connection_pool_efficiency ->
          current_efficiency = Map.get(metrics, :connection_pool_efficiency, 0.0)
          if current_efficiency >= threshold do
            :ok
          else
            {:error, "Connection pool efficiency too low: #{current_efficiency} < #{threshold}"}
          end

        :performance_improvement ->
          current_improvement = Map.get(metrics, :performance_improvement, 0.0)
          if current_improvement >= threshold do
            :ok
          else
            {:error, "Performance improvement insufficient: #{current_improvement} < #{threshold}"}
          end

        _ ->
          Logger.warning("Unknown success criterion: #{criterion}")
          :ok
      end
    end)

    # Check if all criteria passed
    failed_criteria = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(failed_criteria) do
      :ok
    else
      error_messages = Enum.map(failed_criteria, fn {:error, msg} -> msg end)
      {:error, "Criteria not met: #{Enum.join(error_messages, ", ")}"}
    end
  end

  defp perform_health_check(state) do
    # Check current system health and auto-advance if enabled
    if state.auto_advance_enabled do
      case check_advancement_criteria(state) do
        :ok ->
          next_phase = get_next_phase(state.current_phase)
          if next_phase do
            Logger.info("Auto-advancing to phase #{next_phase}")
            case transition_to_phase(next_phase, state) do
              {:ok, new_state} -> new_state
              {:error, reason} ->
                Logger.error("Auto-advance failed: #{inspect(reason)}")
                state
            end
          else
            state
          end

        {:error, reason} ->
          Logger.debug("Auto-advance criteria not met: #{reason}")
          state
      end
    else
      state
    end
  end

  defp schedule_health_check() do
    # Check every 30 minutes
    Process.send_after(self(), :health_check, 30 * 60 * 1000)
  end
end
