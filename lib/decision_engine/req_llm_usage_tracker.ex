# lib/decision_engine/req_llm_usage_tracker.ex
defmodule DecisionEngine.ReqLLMUsageTracker do
  @moduledoc """
  Comprehensive API usage tracking and budget controls for ReqLLM integration.

  This module provides comprehensive API usage tracking, budget controls and spending limits,
  and usage analytics with cost optimization. Supports requirement 8.4 for usage tracking
  and budget controls for different providers and models.
  """

  use GenServer
  require Logger

  @usage_history_limit 1000
  @cost_calculation_timeout 5000

  # Provider pricing information (per 1K tokens)
  @provider_pricing %{
    openai: %{
      "gpt-4o" => %{input: 0.0025, output: 0.01},
      "gpt-4o-mini" => %{input: 0.00015, output: 0.0006},
      "gpt-4-turbo" => %{input: 0.01, output: 0.03},
      "gpt-4" => %{input: 0.03, output: 0.06},
      "gpt-3.5-turbo" => %{input: 0.0005, output: 0.0015}
    },
    anthropic: %{
      "claude-3-5-sonnet-20241022" => %{input: 0.003, output: 0.015},
      "claude-3-5-haiku-20241022" => %{input: 0.00025, output: 0.00125},
      "claude-3-opus-20240229" => %{input: 0.015, output: 0.075},
      "claude-3-sonnet-20240229" => %{input: 0.003, output: 0.015},
      "claude-3-haiku-20240307" => %{input: 0.00025, output: 0.00125}
    },
    ollama: %{
      # Local models - no cost
      default: %{input: 0.0, output: 0.0}
    },
    openrouter: %{
      # OpenRouter has dynamic pricing - these are estimates
      "anthropic/claude-3.5-sonnet" => %{input: 0.003, output: 0.015},
      "openai/gpt-4o" => %{input: 0.0025, output: 0.01}
    },
    lm_studio: %{
      # Local models - no cost
      default: %{input: 0.0, output: 0.0}
    },
    custom: %{
      default: %{input: 0.0, output: 0.0}
    }
  }

  defstruct [
    :usage_stats,
    :budget_limits,
    :cost_tracking,
    :usage_history,
    :alerts_config,
    :optimization_settings
  ]

  # Client API

  @doc """
  Starts the Usage Tracker GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records API usage for a request.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model used
  - usage_data: Map containing usage information (tokens, cost, etc.)

  ## Returns
  - {:ok, updated_stats} if recording successful
  - {:error, reason} if recording fails
  """
  @spec record_usage(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_usage(provider, model, usage_data) do
    GenServer.call(__MODULE__, {:record_usage, provider, model, usage_data})
  end

  @doc """
  Sets budget limits for a provider.

  ## Parameters
  - provider: Atom representing the provider
  - limits: Map containing budget limits (daily, monthly, total)

  ## Returns
  - :ok if limits set successfully
  - {:error, reason} if setting fails
  """
  @spec set_budget_limits(atom(), map()) :: :ok | {:error, term()}
  def set_budget_limits(provider, limits) do
    GenServer.call(__MODULE__, {:set_budget_limits, provider, limits})
  end

  @doc """
  Checks if a request would exceed budget limits.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model
  - estimated_tokens: Integer estimated token usage

  ## Returns
  - :ok if within budget
  - {:error, :budget_exceeded} if would exceed budget
  """
  @spec check_budget_limit(atom(), String.t(), integer()) :: :ok | {:error, :budget_exceeded}
  def check_budget_limit(provider, model, estimated_tokens) do
    GenServer.call(__MODULE__, {:check_budget_limit, provider, model, estimated_tokens})
  end
  @doc """
  Gets current usage statistics for a provider.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, stats} with current usage statistics
  - {:error, reason} if provider not found
  """
  @spec get_usage_stats(atom()) :: {:ok, map()} | {:error, term()}
  def get_usage_stats(provider) do
    GenServer.call(__MODULE__, {:get_usage_stats, provider})
  end

  @doc """
  Gets usage analytics and cost optimization recommendations.

  ## Parameters
  - provider: Atom representing the provider (optional)
  - time_period: Atom representing time period (:daily, :weekly, :monthly)

  ## Returns
  - {:ok, analytics} with usage analytics and recommendations
  """
  @spec get_usage_analytics(atom() | nil, atom()) :: {:ok, map()}
  def get_usage_analytics(provider \\ nil, time_period \\ :daily) do
    GenServer.call(__MODULE__, {:get_usage_analytics, provider, time_period})
  end

  @doc """
  Calculates estimated cost for a request.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model
  - input_tokens: Integer number of input tokens
  - output_tokens: Integer number of output tokens

  ## Returns
  - {:ok, cost} with estimated cost in USD
  - {:error, reason} if calculation fails
  """
  @spec calculate_cost(atom(), String.t(), integer(), integer()) :: {:ok, float()} | {:error, term()}
  def calculate_cost(provider, model, input_tokens, output_tokens) do
    GenServer.call(__MODULE__, {:calculate_cost, provider, model, input_tokens, output_tokens}, @cost_calculation_timeout)
  end

  @doc """
  Gets cost optimization recommendations.

  ## Parameters
  - provider: Atom representing the provider (optional)

  ## Returns
  - {:ok, recommendations} with cost optimization suggestions
  """
  @spec get_cost_optimization_recommendations(atom() | nil) :: {:ok, [map()]}
  def get_cost_optimization_recommendations(provider \\ nil) do
    GenServer.call(__MODULE__, {:get_cost_optimization_recommendations, provider})
  end

  @doc """
  Configures usage alerts and notifications.

  ## Parameters
  - provider: Atom representing the provider
  - alert_config: Map containing alert configuration

  ## Returns
  - :ok if configuration successful
  - {:error, reason} if configuration fails
  """
  @spec configure_alerts(atom(), map()) :: :ok | {:error, term()}
  def configure_alerts(provider, alert_config) do
    GenServer.call(__MODULE__, {:configure_alerts, provider, alert_config})
  end

  @doc """
  Resets usage statistics for a provider.

  ## Parameters
  - provider: Atom representing the provider
  - reset_type: Atom representing what to reset (:daily, :monthly, :all)

  ## Returns
  - :ok if reset successful
  - {:error, reason} if reset fails
  """
  @spec reset_usage_stats(atom(), atom()) :: :ok | {:error, term()}
  def reset_usage_stats(provider, reset_type \\ :daily) do
    GenServer.call(__MODULE__, {:reset_usage_stats, provider, reset_type})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Usage Tracker")

    state = %__MODULE__{
      usage_stats: %{},
      budget_limits: %{},
      cost_tracking: %{},
      usage_history: %{},
      alerts_config: %{},
      optimization_settings: %{
        cost_optimization_enabled: true,
        auto_model_switching: false,
        budget_alerts_enabled: true
      }
    }

    # Schedule periodic cleanup and analytics
    schedule_periodic_tasks()

    {:ok, state}
  end

  @impl true
  def handle_call({:record_usage, provider, model, usage_data}, _from, state) do
    case record_usage_internal(provider, model, usage_data, state) do
      {:ok, updated_state} ->
        # Check for budget alerts
        check_and_send_alerts(provider, updated_state)
        {:reply, {:ok, get_provider_stats(provider, updated_state)}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_budget_limits, provider, limits}, _from, state) do
    case validate_budget_limits(limits) do
      :ok ->
        updated_budget_limits = Map.put(state.budget_limits, provider, limits)
        updated_state = %{state | budget_limits: updated_budget_limits}
        Logger.info("Budget limits set for provider #{provider}: #{inspect(limits)}")
        {:reply, :ok, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:check_budget_limit, provider, model, estimated_tokens}, _from, state) do
    case check_budget_limit_internal(provider, model, estimated_tokens, state) do
      :ok ->
        {:reply, :ok, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_usage_stats, provider}, _from, state) do
    stats = get_provider_stats(provider, state)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call({:get_usage_analytics, provider, time_period}, _from, state) do
    analytics = generate_usage_analytics(provider, time_period, state)
    {:reply, {:ok, analytics}, state}
  end

  @impl true
  def handle_call({:calculate_cost, provider, model, input_tokens, output_tokens}, _from, state) do
    case calculate_cost_internal(provider, model, input_tokens, output_tokens) do
      {:ok, cost} ->
        {:reply, {:ok, cost}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_cost_optimization_recommendations, provider}, _from, state) do
    recommendations = generate_cost_recommendations(provider, state)
    {:reply, {:ok, recommendations}, state}
  end

  @impl true
  def handle_call({:configure_alerts, provider, alert_config}, _from, state) do
    case validate_alert_config(alert_config) do
      :ok ->
        updated_alerts = Map.put(state.alerts_config, provider, alert_config)
        updated_state = %{state | alerts_config: updated_alerts}
        {:reply, :ok, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:reset_usage_stats, provider, reset_type}, _from, state) do
    updated_state = reset_stats_internal(provider, reset_type, state)
    Logger.info("Usage stats reset for provider #{provider}, type: #{reset_type}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_info(:periodic_cleanup, state) do
    updated_state = perform_periodic_cleanup(state)
    schedule_periodic_tasks()
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:generate_analytics, state) do
    generate_and_log_analytics(state)
    {:noreply, state}
  end
  # Private Functions

  defp record_usage_internal(provider, model, usage_data, state) do
    try do
      timestamp = System.system_time(:millisecond)

      # Extract usage information
      input_tokens = Map.get(usage_data, :input_tokens, 0)
      output_tokens = Map.get(usage_data, :output_tokens, 0)
      total_tokens = input_tokens + output_tokens

      # Calculate cost
      {:ok, cost} = calculate_cost_internal(provider, model, input_tokens, output_tokens)

      # Create usage record
      usage_record = %{
        timestamp: timestamp,
        provider: provider,
        model: model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        cost: cost,
        request_id: Map.get(usage_data, :request_id),
        response_time: Map.get(usage_data, :response_time, 0)
      }

      # Update usage statistics
      current_stats = Map.get(state.usage_stats, provider, initialize_provider_stats())
      updated_stats = update_provider_stats(current_stats, usage_record)
      updated_usage_stats = Map.put(state.usage_stats, provider, updated_stats)

      # Update usage history
      current_history = Map.get(state.usage_history, provider, [])
      updated_history = [usage_record | current_history]
      |> Enum.take(@usage_history_limit)  # Limit history size
      updated_usage_history = Map.put(state.usage_history, provider, updated_history)

      # Update cost tracking
      updated_cost_tracking = update_cost_tracking(provider, cost, state.cost_tracking)

      updated_state = %{state |
        usage_stats: updated_usage_stats,
        usage_history: updated_usage_history,
        cost_tracking: updated_cost_tracking
      }

      {:ok, updated_state}
    rescue
      error ->
        Logger.error("Error recording usage for #{provider}/#{model}: #{inspect(error)}")
        {:error, "Failed to record usage: #{inspect(error)}"}
    end
  end

  defp initialize_provider_stats do
    %{
      total_requests: 0,
      total_tokens: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost: 0.0,
      daily_requests: 0,
      daily_tokens: 0,
      daily_cost: 0.0,
      monthly_requests: 0,
      monthly_tokens: 0,
      monthly_cost: 0.0,
      average_response_time: 0.0,
      last_request_time: nil,
      models_used: MapSet.new(),
      daily_reset_time: get_daily_reset_time(),
      monthly_reset_time: get_monthly_reset_time()
    }
  end

  defp update_provider_stats(stats, usage_record) do
    current_time = System.system_time(:millisecond)

    # Check if daily/monthly stats need reset
    stats = maybe_reset_daily_stats(stats, current_time)
    stats = maybe_reset_monthly_stats(stats, current_time)

    # Update statistics
    %{stats |
      total_requests: stats.total_requests + 1,
      total_tokens: stats.total_tokens + usage_record.total_tokens,
      total_input_tokens: stats.total_input_tokens + usage_record.input_tokens,
      total_output_tokens: stats.total_output_tokens + usage_record.output_tokens,
      total_cost: stats.total_cost + usage_record.cost,
      daily_requests: stats.daily_requests + 1,
      daily_tokens: stats.daily_tokens + usage_record.total_tokens,
      daily_cost: stats.daily_cost + usage_record.cost,
      monthly_requests: stats.monthly_requests + 1,
      monthly_tokens: stats.monthly_tokens + usage_record.total_tokens,
      monthly_cost: stats.monthly_cost + usage_record.cost,
      average_response_time: calculate_average_response_time(stats, usage_record.response_time),
      last_request_time: usage_record.timestamp,
      models_used: MapSet.put(stats.models_used, usage_record.model)
    }
  end

  defp calculate_cost_internal(provider, model, input_tokens, output_tokens) do
    case get_model_pricing(provider, model) do
      {:ok, pricing} ->
        input_cost = (input_tokens / 1000.0) * pricing.input
        output_cost = (output_tokens / 1000.0) * pricing.output
        total_cost = input_cost + output_cost
        {:ok, Float.round(total_cost, 6)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_model_pricing(provider, model) do
    case Map.get(@provider_pricing, provider) do
      nil ->
        {:error, "Pricing not available for provider #{provider}"}

      provider_pricing ->
        case Map.get(provider_pricing, model) do
          nil ->
            # Try default pricing for provider
            case Map.get(provider_pricing, "default") do
              nil ->
                {:error, "Pricing not available for model #{model} on provider #{provider}"}
              default_pricing ->
                {:ok, default_pricing}
            end
          pricing ->
            {:ok, pricing}
        end
    end
  end

  defp check_budget_limit_internal(provider, model, estimated_tokens, state) do
    case Map.get(state.budget_limits, provider) do
      nil ->
        :ok  # No budget limits set

      limits ->
        current_stats = Map.get(state.usage_stats, provider, initialize_provider_stats())

        # Calculate estimated cost
        case calculate_cost_internal(provider, model, estimated_tokens, 0) do
          {:ok, estimated_cost} ->
            # Check daily limits
            if Map.has_key?(limits, :daily_cost) do
              if current_stats.daily_cost + estimated_cost > limits.daily_cost do
                {:error, :budget_exceeded}
              else
                check_monthly_limits(limits, current_stats, estimated_cost)
              end
            else
              check_monthly_limits(limits, current_stats, estimated_cost)
            end

          {:error, _} ->
            :ok  # If we can't calculate cost, allow the request
        end
    end
  end

  defp check_monthly_limits(limits, current_stats, estimated_cost) do
    if Map.has_key?(limits, :monthly_cost) do
      if current_stats.monthly_cost + estimated_cost > limits.monthly_cost do
        {:error, :budget_exceeded}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp validate_budget_limits(limits) do
    required_fields = [:daily_cost, :monthly_cost]
    errors = []

    errors = Enum.reduce(required_fields, errors, fn field, acc ->
      case Map.get(limits, field) do
        nil -> acc
        value when is_number(value) and value > 0 -> acc
        _ -> ["#{field} must be a positive number" | acc]
      end
    end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp get_provider_stats(provider, state) do
    Map.get(state.usage_stats, provider, initialize_provider_stats())
  end

  defp generate_usage_analytics(provider, time_period, state) do
    stats = if provider do
      %{provider => get_provider_stats(provider, state)}
    else
      state.usage_stats
    end

    %{
      time_period: time_period,
      providers: stats,
      total_cost: calculate_total_cost(stats, time_period),
      total_requests: calculate_total_requests(stats, time_period),
      total_tokens: calculate_total_tokens(stats, time_period),
      cost_breakdown: generate_cost_breakdown(stats, time_period),
      usage_trends: generate_usage_trends(provider, time_period, state),
      recommendations: generate_cost_recommendations(provider, state)
    }
  end

  defp generate_cost_recommendations(provider, state) do
    recommendations = []

    # Analyze usage patterns and generate recommendations
    stats = if provider do
      %{provider => get_provider_stats(provider, state)}
    else
      state.usage_stats
    end

    recommendations = Enum.reduce(stats, recommendations, fn {prov, prov_stats}, acc ->
      # High cost models recommendation
      if prov_stats.daily_cost > 10.0 do
        [%{
          type: :cost_optimization,
          provider: prov,
          message: "Consider using more cost-effective models for routine tasks",
          potential_savings: calculate_potential_savings(prov_stats)
        } | acc]
      else
        acc
      end
    end)

    # Token efficiency recommendations
    recommendations = Enum.reduce(stats, recommendations, fn {prov, prov_stats}, acc ->
      avg_tokens_per_request = if prov_stats.total_requests > 0 do
        prov_stats.total_tokens / prov_stats.total_requests
      else
        0
      end

      if avg_tokens_per_request > 5000 do
        [%{
          type: :token_optimization,
          provider: prov,
          message: "Consider optimizing prompts to reduce token usage",
          average_tokens: avg_tokens_per_request
        } | acc]
      else
        acc
      end
    end)

    recommendations
  end

  defp calculate_total_cost(stats, time_period) do
    Enum.reduce(stats, 0.0, fn {_provider, prov_stats}, acc ->
      cost = case time_period do
        :daily -> prov_stats.daily_cost
        :monthly -> prov_stats.monthly_cost
        :total -> prov_stats.total_cost
      end
      acc + cost
    end)
  end

  defp calculate_total_requests(stats, time_period) do
    Enum.reduce(stats, 0, fn {_provider, prov_stats}, acc ->
      requests = case time_period do
        :daily -> prov_stats.daily_requests
        :monthly -> prov_stats.monthly_requests
        :total -> prov_stats.total_requests
      end
      acc + requests
    end)
  end

  defp calculate_total_tokens(stats, time_period) do
    Enum.reduce(stats, 0, fn {_provider, prov_stats}, acc ->
      tokens = case time_period do
        :daily -> prov_stats.daily_tokens
        :monthly -> prov_stats.monthly_tokens
        :total -> prov_stats.total_tokens
      end
      acc + tokens
    end)
  end

  defp generate_cost_breakdown(stats, time_period) do
    Enum.map(stats, fn {provider, prov_stats} ->
      cost = case time_period do
        :daily -> prov_stats.daily_cost
        :monthly -> prov_stats.monthly_cost
        :total -> prov_stats.total_cost
      end

      %{
        provider: provider,
        cost: cost,
        models: MapSet.to_list(prov_stats.models_used)
      }
    end)
  end

  defp generate_usage_trends(_provider, _time_period, _state) do
    # Placeholder for usage trend analysis
    %{
      trend: :stable,
      growth_rate: 0.0,
      peak_hours: [],
      recommendations: []
    }
  end

  defp calculate_potential_savings(stats) do
    # Estimate potential savings by switching to cheaper models
    stats.daily_cost * 0.3  # Assume 30% potential savings
  end

  defp update_cost_tracking(provider, cost, cost_tracking) do
    current_tracking = Map.get(cost_tracking, provider, %{
      daily_total: 0.0,
      monthly_total: 0.0,
      last_updated: System.system_time(:millisecond)
    })

    %{current_tracking |
      daily_total: current_tracking.daily_total + cost,
      monthly_total: current_tracking.monthly_total + cost,
      last_updated: System.system_time(:millisecond)
    }
    |> then(&Map.put(cost_tracking, provider, &1))
  end

  defp check_and_send_alerts(provider, state) do
    case Map.get(state.alerts_config, provider) do
      nil -> :ok
      alert_config ->
        current_stats = get_provider_stats(provider, state)
        check_cost_alerts(provider, current_stats, alert_config)
        check_usage_alerts(provider, current_stats, alert_config)
    end
  end

  defp check_cost_alerts(provider, stats, alert_config) do
    daily_threshold = Map.get(alert_config, :daily_cost_threshold)
    monthly_threshold = Map.get(alert_config, :monthly_cost_threshold)

    if daily_threshold && stats.daily_cost > daily_threshold do
      Logger.warning("Daily cost threshold exceeded for #{provider}: $#{stats.daily_cost}")
    end

    if monthly_threshold && stats.monthly_cost > monthly_threshold do
      Logger.warning("Monthly cost threshold exceeded for #{provider}: $#{stats.monthly_cost}")
    end
  end

  defp check_usage_alerts(provider, stats, alert_config) do
    daily_requests_threshold = Map.get(alert_config, :daily_requests_threshold)

    if daily_requests_threshold && stats.daily_requests > daily_requests_threshold do
      Logger.warning("Daily requests threshold exceeded for #{provider}: #{stats.daily_requests}")
    end
  end

  defp validate_alert_config(alert_config) do
    # Basic validation for alert configuration
    valid_keys = [:daily_cost_threshold, :monthly_cost_threshold, :daily_requests_threshold]

    invalid_keys = Map.keys(alert_config) -- valid_keys
    if length(invalid_keys) > 0 do
      {:error, "Invalid alert config keys: #{Enum.join(invalid_keys, ", ")}"}
    else
      :ok
    end
  end

  defp reset_stats_internal(provider, reset_type, state) do
    case Map.get(state.usage_stats, provider) do
      nil -> state
      current_stats ->
        updated_stats = case reset_type do
          :daily ->
            %{current_stats |
              daily_requests: 0,
              daily_tokens: 0,
              daily_cost: 0.0,
              daily_reset_time: get_daily_reset_time()
            }
          :monthly ->
            %{current_stats |
              monthly_requests: 0,
              monthly_tokens: 0,
              monthly_cost: 0.0,
              monthly_reset_time: get_monthly_reset_time()
            }
          :all ->
            initialize_provider_stats()
        end

        updated_usage_stats = Map.put(state.usage_stats, provider, updated_stats)
        %{state | usage_stats: updated_usage_stats}
    end
  end

  defp schedule_periodic_tasks do
    # Schedule cleanup every hour
    Process.send_after(self(), :periodic_cleanup, 3_600_000)
    # Schedule analytics generation every 6 hours
    Process.send_after(self(), :generate_analytics, 21_600_000)
  end

  defp perform_periodic_cleanup(state) do
    # Clean up old usage history entries
    updated_usage_history = Enum.map(state.usage_history, fn {provider, history} ->
      # Keep only last 1000 entries
      cleaned_history = Enum.take(history, @usage_history_limit)
      {provider, cleaned_history}
    end)
    |> Map.new()

    %{state | usage_history: updated_usage_history}
  end

  defp generate_and_log_analytics(state) do
    analytics = generate_usage_analytics(nil, :daily, state)
    Logger.info("Daily usage analytics: #{inspect(analytics, limit: :infinity)}")
  end

  defp maybe_reset_daily_stats(stats, current_time) do
    if current_time > stats.daily_reset_time do
      %{stats |
        daily_requests: 0,
        daily_tokens: 0,
        daily_cost: 0.0,
        daily_reset_time: get_daily_reset_time()
      }
    else
      stats
    end
  end

  defp maybe_reset_monthly_stats(stats, current_time) do
    if current_time > stats.monthly_reset_time do
      %{stats |
        monthly_requests: 0,
        monthly_tokens: 0,
        monthly_cost: 0.0,
        monthly_reset_time: get_monthly_reset_time()
      }
    else
      stats
    end
  end

  defp get_daily_reset_time do
    # Next midnight
    now = DateTime.utc_now()
    tomorrow = DateTime.add(now, 1, :day)
    %{tomorrow | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    |> DateTime.to_unix(:millisecond)
  end

  defp get_monthly_reset_time do
    # First day of next month
    now = DateTime.utc_now()
    next_month = DateTime.add(now, 32, :day)  # Add 32 days to ensure we're in next month
    %{next_month | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    |> DateTime.to_unix(:millisecond)
  end

  defp calculate_average_response_time(stats, new_response_time) do
    if stats.total_requests == 0 do
      new_response_time
    else
      # Calculate running average
      total_time = stats.average_response_time * stats.total_requests
      (total_time + new_response_time) / (stats.total_requests + 1)
    end
  end
end
