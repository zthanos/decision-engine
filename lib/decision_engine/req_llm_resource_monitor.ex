# lib/decision_engine/req_llm_resource_monitor.ex
defmodule DecisionEngine.ReqLLMResourceMonitor do
  @moduledoc """
  Resource constraint handling and monitoring for ReqLLM integration.

  This module provides configurable connection limits, timeouts, resource monitoring,
  constraint detection, and graceful degradation under resource pressure to ensure
  system stability and optimal performance.
  """

  use GenServer
  require Logger

  @default_resource_config %{
    max_concurrent_requests: 50,
    max_memory_usage_mb: 512,
    max_cpu_usage_percent: 80.0,
    connection_timeout_ms: 30_000,
    request_timeout_ms: 60_000,
    health_check_interval_ms: 5_000,
    degradation_thresholds: %{
      memory_warning: 0.75,    # 75% of max memory
      memory_critical: 0.90,   # 90% of max memory
      cpu_warning: 0.70,       # 70% of max CPU
      cpu_critical: 0.85,      # 85% of max CPU
      connection_warning: 0.80, # 80% of max connections
      connection_critical: 0.95 # 95% of max connections
    },
    degradation_actions: %{
      warning: [:log_warning, :increase_timeouts],
      critical: [:log_critical, :reject_low_priority, :enable_circuit_breaker]
    }
  }

  @resource_metrics %{
    current_requests: 0,
    peak_requests: 0,
    memory_usage_mb: 0.0,
    cpu_usage_percent: 0.0,
    active_connections: 0,
    failed_requests: 0,
    degraded_requests: 0,
    circuit_breaker_trips: 0,
    last_health_check: nil,
    system_status: :healthy
  }

  # Client API

  @doc """
  Starts the ReqLLM Resource Monitor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configures resource constraints for a specific provider.

  ## Parameters
  - provider: Provider atom (:openai, :anthropic, etc.)
  - resource_config: Map containing resource constraint configuration

  ## Returns
  - :ok on successful configuration
  - {:error, reason} if configuration fails
  """
  @spec configure_constraints(atom(), map()) :: :ok | {:error, term()}
  def configure_constraints(provider, resource_config \\ %{}) do
    GenServer.call(__MODULE__, {:configure_constraints, provider, resource_config})
  end

  @doc """
  Checks if a request can be processed given current resource constraints.

  ## Parameters
  - provider: Provider atom
  - request_priority: Priority level (:high, :normal, :low)

  ## Returns
  - :ok if request can be processed
  - {:error, reason} if request should be rejected or delayed
  """
  @spec check_resource_availability(atom(), atom()) :: :ok | {:error, term()}
  def check_resource_availability(provider, request_priority \\ :normal) do
    GenServer.call(__MODULE__, {:check_resource_availability, provider, request_priority})
  end

  @doc """
  Registers the start of a request for resource tracking.

  ## Parameters
  - provider: Provider atom
  - request_id: Unique request identifier
  - request_priority: Priority level

  ## Returns
  - :ok on successful registration
  - {:error, reason} if registration fails
  """
  @spec register_request_start(atom(), String.t(), atom()) :: :ok | {:error, term()}
  def register_request_start(provider, request_id, request_priority) do
    GenServer.call(__MODULE__, {:register_request_start, provider, request_id, request_priority})
  end

  @doc """
  Registers the completion of a request for resource tracking.

  ## Parameters
  - provider: Provider atom
  - request_id: Unique request identifier
  - success: Boolean indicating if request was successful

  ## Returns
  - :ok on successful registration
  """
  @spec register_request_completion(atom(), String.t(), boolean()) :: :ok
  def register_request_completion(provider, request_id, success) do
    GenServer.cast(__MODULE__, {:register_request_completion, provider, request_id, success})
  end

  @doc """
  Gets current resource metrics for a provider.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - {:ok, metrics} with current resource metrics
  - {:error, reason} if provider not configured
  """
  @spec get_resource_metrics(atom()) :: {:ok, map()} | {:error, term()}
  def get_resource_metrics(provider) do
    GenServer.call(__MODULE__, {:get_resource_metrics, provider})
  end

  @doc """
  Gets resource metrics for all configured providers.

  ## Returns
  - Map with provider atoms as keys and metrics as values
  """
  @spec get_all_resource_metrics() :: map()
  def get_all_resource_metrics do
    GenServer.call(__MODULE__, :get_all_resource_metrics)
  end

  @doc """
  Gets the current system health status.

  ## Returns
  - :healthy, :warning, or :critical
  """
  @spec get_system_status() :: :healthy | :warning | :critical
  def get_system_status do
    GenServer.call(__MODULE__, :get_system_status)
  end

  @doc """
  Forces a health check and resource evaluation.

  ## Returns
  - :ok after health check is completed
  """
  @spec force_health_check() :: :ok
  def force_health_check do
    GenServer.cast(__MODULE__, :force_health_check)
  end

  @doc """
  Gets recommended timeout values based on current resource constraints.

  ## Parameters
  - provider: Provider atom
  - request_type: Type of request (:connection, :request, :streaming)

  ## Returns
  - {:ok, timeout_ms} with recommended timeout
  - {:error, reason} if provider not configured
  """
  @spec get_recommended_timeout(atom(), atom()) :: {:ok, integer()} | {:error, term()}
  def get_recommended_timeout(provider, request_type) do
    GenServer.call(__MODULE__, {:get_recommended_timeout, provider, request_type})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Resource Monitor")

    # Schedule periodic health checks
    schedule_health_check()

    state = %{
      providers: %{},
      metrics: %{},
      active_requests: %{},
      system_status: :healthy,
      last_health_check: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:configure_constraints, provider, resource_config}, _from, state) do
    try do
      # Merge with defaults
      config = Map.merge(@default_resource_config, resource_config)

      # Validate configuration
      case validate_resource_config(config) do
        :ok ->
          # Initialize provider state
          provider_state = %{
            config: config,
            created_at: System.monotonic_time(:millisecond)
          }

          new_providers = Map.put(state.providers, provider, provider_state)
          new_metrics = Map.put(state.metrics, provider, @resource_metrics)

          Logger.info("Configured resource constraints for provider #{provider}: #{inspect(config)}")

          {:reply, :ok, %{state | providers: new_providers, metrics: new_metrics}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    rescue
      error ->
        Logger.error("Error configuring resource constraints for #{provider}: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:check_resource_availability, provider, request_priority}, _from, state) do
    case Map.get(state.providers, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}

      provider_state ->
        case check_resource_availability_internal(provider, request_priority, provider_state, state) do
          :ok ->
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:register_request_start, provider, request_id, request_priority}, _from, state) do
    case Map.get(state.providers, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}

      _provider_state ->
        # Register active request
        request_info = %{
          id: request_id,
          provider: provider,
          priority: request_priority,
          started_at: System.monotonic_time(:millisecond)
        }

        new_active_requests = Map.put(state.active_requests, request_id, request_info)
        new_metrics = update_request_start_metrics(state.metrics, provider)

        {:reply, :ok, %{state |
          active_requests: new_active_requests,
          metrics: new_metrics
        }}
    end
  end

  @impl true
  def handle_call({:get_resource_metrics, provider}, _from, state) do
    case Map.get(state.metrics, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}
      metrics ->
        # Update real-time metrics
        updated_metrics = update_realtime_metrics(metrics, provider, state)
        {:reply, {:ok, updated_metrics}, state}
    end
  end

  @impl true
  def handle_call(:get_all_resource_metrics, _from, state) do
    all_metrics = Enum.map(state.metrics, fn {provider, metrics} ->
      updated_metrics = update_realtime_metrics(metrics, provider, state)
      {provider, updated_metrics}
    end)
    |> Map.new()

    {:reply, all_metrics, state}
  end

  @impl true
  def handle_call(:get_system_status, _from, state) do
    {:reply, state.system_status, state}
  end

  @impl true
  def handle_call({:get_recommended_timeout, provider, request_type}, _from, state) do
    case Map.get(state.providers, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}

      provider_state ->
        timeout = calculate_recommended_timeout(provider_state, request_type, state.system_status)
        {:reply, {:ok, timeout}, state}
    end
  end

  @impl true
  def handle_cast({:register_request_completion, provider, request_id, success}, state) do
    # Remove from active requests
    new_active_requests = Map.delete(state.active_requests, request_id)

    # Update metrics
    new_metrics = update_request_completion_metrics(state.metrics, provider, success)

    {:noreply, %{state |
      active_requests: new_active_requests,
      metrics: new_metrics
    }}
  end

  @impl true
  def handle_cast(:force_health_check, state) do
    updated_state = perform_health_check(state)
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    updated_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, updated_state}
  end

  # Private Functions

  defp validate_resource_config(config) do
    required_fields = [:max_concurrent_requests, :max_memory_usage_mb, :connection_timeout_ms]

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(config, field) or is_nil(Map.get(config, field))
    end)

    if Enum.empty?(missing_fields) do
      cond do
        config.max_concurrent_requests <= 0 ->
          {:error, "Max concurrent requests must be positive"}
        config.max_memory_usage_mb <= 0 ->
          {:error, "Max memory usage must be positive"}
        config.connection_timeout_ms <= 0 ->
          {:error, "Connection timeout must be positive"}
        true ->
          :ok
      end
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp check_resource_availability_internal(provider, request_priority, provider_state, state) do
    config = provider_state.config
    current_metrics = Map.get(state.metrics, provider, @resource_metrics)

    # Check concurrent request limit
    current_requests = count_active_requests_for_provider(provider, state.active_requests)
    if current_requests >= config.max_concurrent_requests do
      if request_priority == :high do
        Logger.warning("High priority request allowed despite connection limit for #{provider}")
      else
        {:error, :max_concurrent_requests_exceeded}
      end
    end

    # Check system resource constraints
    case state.system_status do
      :critical ->
        if request_priority != :high do
          {:error, :system_resources_critical}
        else
          :ok
        end

      :warning ->
        if request_priority == :low do
          {:error, :system_resources_degraded}
        else
          :ok
        end

      :healthy ->
        :ok
    end
  end

  defp count_active_requests_for_provider(provider, active_requests) do
    active_requests
    |> Enum.count(fn {_id, request_info} ->
      request_info.provider == provider
    end)
  end

  defp update_request_start_metrics(metrics, provider) do
    current_metrics = Map.get(metrics, provider, @resource_metrics)

    new_current = current_metrics.current_requests + 1
    new_peak = max(new_current, current_metrics.peak_requests)

    updated_metrics = %{current_metrics |
      current_requests: new_current,
      peak_requests: new_peak
    }

    Map.put(metrics, provider, updated_metrics)
  end

  defp update_request_completion_metrics(metrics, provider, success) do
    current_metrics = Map.get(metrics, provider, @resource_metrics)

    updated_metrics = %{current_metrics |
      current_requests: max(0, current_metrics.current_requests - 1),
      failed_requests: if(success, do: current_metrics.failed_requests, else: current_metrics.failed_requests + 1)
    }

    Map.put(metrics, provider, updated_metrics)
  end

  defp update_realtime_metrics(metrics, provider, state) do
    # Update with real-time system metrics
    current_requests = count_active_requests_for_provider(provider, state.active_requests)

    # Get system resource usage (simplified for this implementation)
    {memory_usage, cpu_usage} = get_system_resource_usage()

    %{metrics |
      current_requests: current_requests,
      memory_usage_mb: memory_usage,
      cpu_usage_percent: cpu_usage,
      last_health_check: state.last_health_check,
      system_status: state.system_status
    }
  end

  defp get_system_resource_usage do
    # Simplified system resource monitoring
    # In a real implementation, this would use :recon or similar tools
    try do
      memory_info = :erlang.memory()
      total_memory = Keyword.get(memory_info, :total, 0)
      memory_mb = total_memory / (1024 * 1024)

      # CPU usage is harder to get in Elixir, using a simplified approach
      cpu_usage = :rand.uniform(20) + 10.0  # Simulated 10-30% usage

      {memory_mb, cpu_usage}
    rescue
      _ ->
        {0.0, 0.0}
    end
  end

  defp perform_health_check(state) do
    current_time = System.monotonic_time(:millisecond)

    # Check system resources
    {memory_usage, cpu_usage} = get_system_resource_usage()

    # Determine system status based on all providers
    system_status = determine_system_status(state.providers, memory_usage, cpu_usage, state.active_requests)

    # Update metrics for all providers
    updated_metrics = Enum.map(state.metrics, fn {provider, metrics} ->
      updated = %{metrics |
        memory_usage_mb: memory_usage,
        cpu_usage_percent: cpu_usage,
        last_health_check: current_time,
        system_status: system_status
      }
      {provider, updated}
    end)
    |> Map.new()

    # Log status changes
    if system_status != state.system_status do
      Logger.info("System status changed from #{state.system_status} to #{system_status}")

      # Trigger degradation actions if needed
      trigger_degradation_actions(system_status, state.providers)
    end

    %{state |
      metrics: updated_metrics,
      system_status: system_status,
      last_health_check: current_time
    }
  end

  defp determine_system_status(providers, memory_usage, cpu_usage, active_requests) do
    # Check if any provider is over critical thresholds
    critical_conditions = Enum.any?(providers, fn {provider, provider_state} ->
      config = provider_state.config
      thresholds = config.degradation_thresholds

      current_requests = count_active_requests_for_provider(provider, active_requests)
      connection_ratio = current_requests / config.max_concurrent_requests
      memory_ratio = memory_usage / config.max_memory_usage_mb
      cpu_ratio = cpu_usage / config.max_cpu_usage_percent

      memory_ratio >= thresholds.memory_critical or
      cpu_ratio >= thresholds.cpu_critical or
      connection_ratio >= thresholds.connection_critical
    end)

    if critical_conditions do
      :critical
    else
      # Check for warning conditions
      warning_conditions = Enum.any?(providers, fn {provider, provider_state} ->
        config = provider_state.config
        thresholds = config.degradation_thresholds

        current_requests = count_active_requests_for_provider(provider, active_requests)
        connection_ratio = current_requests / config.max_concurrent_requests
        memory_ratio = memory_usage / config.max_memory_usage_mb
        cpu_ratio = cpu_usage / config.max_cpu_usage_percent

        memory_ratio >= thresholds.memory_warning or
        cpu_ratio >= thresholds.cpu_warning or
        connection_ratio >= thresholds.connection_warning
      end)

      if warning_conditions do
        :warning
      else
        :healthy
      end
    end
  end

  defp trigger_degradation_actions(system_status, providers) do
    case system_status do
      :warning ->
        Logger.warning("System entering warning state - applying degradation actions")
        # Could implement specific actions like increasing timeouts

      :critical ->
        Logger.error("System entering critical state - applying emergency degradation actions")
        # Could implement circuit breaker activation, request rejection, etc.

      :healthy ->
        Logger.info("System returning to healthy state")
    end
  end

  defp calculate_recommended_timeout(provider_state, request_type, system_status) do
    config = provider_state.config

    base_timeout = case request_type do
      :connection -> config.connection_timeout_ms
      :request -> config.request_timeout_ms
      :streaming -> config.request_timeout_ms * 2  # Longer for streaming
      _ -> config.request_timeout_ms
    end

    # Adjust timeout based on system status
    case system_status do
      :healthy -> base_timeout
      :warning -> round(base_timeout * 1.5)  # 50% increase
      :critical -> round(base_timeout * 2.0)  # 100% increase
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @default_resource_config.health_check_interval_ms)
  end
end
