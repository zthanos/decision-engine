# lib/decision_engine/streaming_backpressure_handler.ex
defmodule DecisionEngine.StreamingBackpressureHandler do
  @moduledoc """
  Handles backpressure and flow control for streaming operations.

  This module provides comprehensive backpressure handling to prevent client
  overwhelming and ensure system stability under load. It includes:
  - Adaptive streaming rate based on client capacity
  - Flow control mechanisms to prevent buffer overflow
  - Monitoring for backpressure conditions
  - Dynamic rate limiting based on system load
  - Client-specific flow control policies
  """

  use GenServer
  require Logger

  @typedoc """
  Backpressure configuration options.
  """
  @type backpressure_config :: %{
    max_chunks_per_second: non_neg_integer(),
    chunk_rate_window_ms: non_neg_integer(),
    adaptive_rate_enabled: boolean(),
    client_buffer_size: non_neg_integer(),
    backpressure_threshold: float(),
    rate_reduction_factor: float(),
    rate_increase_factor: float(),
    min_chunk_delay_ms: non_neg_integer(),
    max_chunk_delay_ms: non_neg_integer(),
    monitoring_enabled: boolean()
  }

  @typedoc """
  Client flow control state.
  """
  @type client_flow_state :: %{
    client_id: String.t(),
    current_rate: float(),
    target_rate: float(),
    buffer_usage: float(),
    last_chunk_time: integer(),
    chunk_timestamps: [integer()],
    backpressure_detected: boolean(),
    rate_adjustments: non_neg_integer(),
    total_chunks_sent: non_neg_integer(),
    total_bytes_sent: non_neg_integer()
  }

  @typedoc """
  System load metrics for adaptive rate control.
  """
  @type system_load_metrics :: %{
    cpu_usage: float(),
    memory_usage: float(),
    active_sessions: non_neg_integer(),
    total_chunk_rate: float(),
    network_latency_ms: float()
  }

  # Default backpressure configuration
  @default_config %{
    max_chunks_per_second: 50,
    chunk_rate_window_ms: 1000,
    adaptive_rate_enabled: true,
    client_buffer_size: 1024 * 1024,  # 1MB buffer
    backpressure_threshold: 0.8,      # 80% buffer usage triggers backpressure
    rate_reduction_factor: 0.5,       # Reduce rate by 50% when backpressure detected
    rate_increase_factor: 1.1,        # Increase rate by 10% when backpressure clears
    min_chunk_delay_ms: 10,           # Minimum 10ms between chunks
    max_chunk_delay_ms: 1000,         # Maximum 1s delay for flow control
    monitoring_enabled: true
  }

  # System load thresholds for adaptive rate control
  @system_load_thresholds %{
    cpu_high: 0.8,      # 80% CPU usage
    memory_high: 0.85,  # 85% memory usage
    latency_high: 500   # 500ms network latency
  }

  ## Public API

  @doc """
  Starts the backpressure handler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a chunk should be sent or delayed due to backpressure.

  ## Parameters
  - client_id: Identifier for the client/session
  - chunk_size: Size of the chunk to be sent
  - opts: Additional options for flow control

  ## Returns
  - {:ok, :send} if chunk can be sent immediately
  - {:ok, {:delay, milliseconds}} if chunk should be delayed
  - {:error, :backpressure} if severe backpressure detected
  """
  @spec should_send_chunk(String.t(), non_neg_integer(), keyword()) ::
    {:ok, :send | {:delay, non_neg_integer()}} | {:error, :backpressure}
  def should_send_chunk(client_id, chunk_size, opts \\ []) do
    GenServer.call(__MODULE__, {:should_send_chunk, client_id, chunk_size, opts})
  end

  @doc """
  Records that a chunk was sent to update flow control state.

  ## Parameters
  - client_id: Identifier for the client/session
  - chunk_size: Size of the chunk that was sent
  - send_time: Timestamp when chunk was sent (optional, uses current time)
  """
  @spec record_chunk_sent(String.t(), non_neg_integer(), integer() | nil) :: :ok
  def record_chunk_sent(client_id, chunk_size, send_time \\ nil) do
    GenServer.cast(__MODULE__, {:record_chunk_sent, client_id, chunk_size, send_time})
  end

  @doc """
  Updates client buffer usage for backpressure detection.

  ## Parameters
  - client_id: Identifier for the client/session
  - buffer_usage: Current buffer usage as percentage (0.0 to 1.0)
  """
  @spec update_client_buffer_usage(String.t(), float()) :: :ok
  def update_client_buffer_usage(client_id, buffer_usage) do
    GenServer.cast(__MODULE__, {:update_buffer_usage, client_id, buffer_usage})
  end

  @doc """
  Gets current flow control state for a client.

  ## Parameters
  - client_id: Identifier for the client/session

  ## Returns
  - {:ok, flow_state} with current flow control information
  - {:error, :not_found} if client not found
  """
  @spec get_client_flow_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_client_flow_state(client_id) do
    GenServer.call(__MODULE__, {:get_flow_state, client_id})
  end

  @doc """
  Gets system-wide backpressure metrics.

  ## Returns
  - Map with system backpressure statistics
  """
  @spec get_system_metrics() :: map()
  def get_system_metrics do
    GenServer.call(__MODULE__, :get_system_metrics)
  end

  @doc """
  Removes a client from flow control tracking (cleanup).

  ## Parameters
  - client_id: Identifier for the client/session to remove
  """
  @spec remove_client(String.t()) :: :ok
  def remove_client(client_id) do
    GenServer.cast(__MODULE__, {:remove_client, client_id})
  end

  @doc """
  Updates system load metrics for adaptive rate control.

  ## Parameters
  - metrics: System load metrics map
  """
  @spec update_system_load(system_load_metrics()) :: :ok
  def update_system_load(metrics) do
    GenServer.cast(__MODULE__, {:update_system_load, metrics})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, @default_config)

    state = %{
      config: config,
      client_states: %{},
      system_load: %{
        cpu_usage: 0.0,
        memory_usage: 0.0,
        active_sessions: 0,
        total_chunk_rate: 0.0,
        network_latency_ms: 0.0
      },
      global_metrics: %{
        total_chunks_delayed: 0,
        total_backpressure_events: 0,
        average_delay_ms: 0.0,
        peak_concurrent_clients: 0
      }
    }

    # Start periodic system monitoring if enabled
    if config.monitoring_enabled do
      schedule_system_monitoring()
    end

    Logger.info("StreamingBackpressureHandler started with config: #{inspect(config)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:should_send_chunk, client_id, chunk_size, opts}, _from, state) do
    # Get or create client flow state
    client_state = get_or_create_client_state(client_id, state)

    # Check flow control conditions
    case check_flow_control(client_state, chunk_size, state) do
      {:ok, :send, updated_client_state} ->
        new_state = update_client_state(client_id, updated_client_state, state)
        {:reply, {:ok, :send}, new_state}

      {:ok, {:delay, delay_ms}, updated_client_state} ->
        new_state = update_client_state(client_id, updated_client_state, state)
        new_state = update_global_metrics(new_state, :chunks_delayed)
        {:reply, {:ok, {:delay, delay_ms}}, new_state}

      {:error, :severe_backpressure, updated_client_state} ->
        new_state = update_client_state(client_id, updated_client_state, state)
        new_state = update_global_metrics(new_state, :backpressure_events)
        {:reply, {:error, :backpressure}, new_state}
    end
  end

  @impl true
  def handle_call({:get_flow_state, client_id}, _from, state) do
    case Map.get(state.client_states, client_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      client_state ->
        flow_info = build_flow_state_info(client_state)
        {:reply, {:ok, flow_info}, state}
    end
  end

  @impl true
  def handle_call(:get_system_metrics, _from, state) do
    metrics = build_system_metrics(state)
    {:reply, metrics, state}
  end

  @impl true
  def handle_cast({:record_chunk_sent, client_id, chunk_size, send_time}, state) do
    client_state = get_or_create_client_state(client_id, state)
    timestamp = send_time || System.monotonic_time(:millisecond)

    # Update client state with sent chunk
    updated_client_state = record_chunk_in_client_state(client_state, chunk_size, timestamp, state.config)

    new_state = update_client_state(client_id, updated_client_state, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_buffer_usage, client_id, buffer_usage}, state) do
    client_state = get_or_create_client_state(client_id, state)

    # Update buffer usage and check for backpressure
    updated_client_state = update_buffer_usage_in_state(client_state, buffer_usage, state.config)

    new_state = update_client_state(client_id, updated_client_state, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:remove_client, client_id}, state) do
    Logger.debug("Removing client #{client_id} from backpressure tracking")

    new_client_states = Map.delete(state.client_states, client_id)
    new_state = %{state | client_states: new_client_states}

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_system_load, metrics}, state) do
    # Update system load and adjust global flow control if needed
    new_system_load = Map.merge(state.system_load, metrics)
    new_state = %{state | system_load: new_system_load}

    # Adjust client rates based on system load if adaptive rate is enabled
    if state.config.adaptive_rate_enabled do
      adjusted_state = adjust_rates_for_system_load(new_state)
      {:noreply, adjusted_state}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:system_monitoring, state) do
    # Perform periodic system monitoring
    new_state = perform_system_monitoring(state)

    # Schedule next monitoring cycle
    schedule_system_monitoring()

    {:noreply, new_state}
  end

  ## Private Functions

  # Get or create client flow control state
  defp get_or_create_client_state(client_id, state) do
    Map.get(state.client_states, client_id, %{
      client_id: client_id,
      current_rate: state.config.max_chunks_per_second,
      target_rate: state.config.max_chunks_per_second,
      buffer_usage: 0.0,
      last_chunk_time: 0,
      chunk_timestamps: [],
      backpressure_detected: false,
      rate_adjustments: 0,
      total_chunks_sent: 0,
      total_bytes_sent: 0
    })
  end

  # Check flow control conditions and determine action
  defp check_flow_control(client_state, chunk_size, state) do
    current_time = System.monotonic_time(:millisecond)

    # Check rate limiting
    case check_rate_limit(client_state, current_time, state.config) do
      {:ok, :within_limit} ->
        # Check backpressure conditions
        case check_backpressure_conditions(client_state, chunk_size, state) do
          {:ok, :no_backpressure} ->
            {:ok, :send, client_state}

          {:ok, {:mild_backpressure, delay_ms}} ->
            updated_state = adjust_rate_for_backpressure(client_state, :mild, state.config)
            {:ok, {:delay, delay_ms}, updated_state}

          {:error, :severe_backpressure} ->
            updated_state = adjust_rate_for_backpressure(client_state, :severe, state.config)
            {:error, :severe_backpressure, updated_state}
        end

      {:error, :rate_limit_exceeded, delay_ms} ->
        {:ok, {:delay, delay_ms}, client_state}
    end
  end

  # Check if client is within rate limits
  defp check_rate_limit(client_state, current_time, config) do
    # Clean old timestamps outside the rate window
    window_start = current_time - config.chunk_rate_window_ms
    recent_chunks = Enum.filter(client_state.chunk_timestamps, &(&1 >= window_start))

    current_rate = length(recent_chunks)
    max_rate = trunc(client_state.current_rate)

    if current_rate >= max_rate do
      # Calculate delay needed to stay within rate limit
      if length(recent_chunks) > 0 do
        oldest_chunk_time = Enum.min(recent_chunks)
        delay_needed = config.chunk_rate_window_ms - (current_time - oldest_chunk_time)
        delay_ms = max(config.min_chunk_delay_ms, min(delay_needed, config.max_chunk_delay_ms))
        {:error, :rate_limit_exceeded, delay_ms}
      else
        {:error, :rate_limit_exceeded, config.min_chunk_delay_ms}
      end
    else
      {:ok, :within_limit}
    end
  end

  # Check backpressure conditions
  defp check_backpressure_conditions(client_state, chunk_size, state) do
    # Check client buffer usage
    buffer_pressure = client_state.buffer_usage

    # Check system load pressure
    system_pressure = calculate_system_pressure(state.system_load)

    # Combine pressures for overall assessment
    total_pressure = max(buffer_pressure, system_pressure)

    cond do
      total_pressure >= 0.95 ->
        # Severe backpressure - reject chunk
        {:error, :severe_backpressure}

      total_pressure >= state.config.backpressure_threshold ->
        # Mild backpressure - delay chunk
        delay_ms = calculate_backpressure_delay(total_pressure, state.config)
        {:ok, {:mild_backpressure, delay_ms}}

      true ->
        # No backpressure
        {:ok, :no_backpressure}
    end
  end

  # Calculate system pressure from load metrics
  defp calculate_system_pressure(system_load) do
    cpu_pressure = system_load.cpu_usage / @system_load_thresholds.cpu_high
    memory_pressure = system_load.memory_usage / @system_load_thresholds.memory_high
    latency_pressure = system_load.network_latency_ms / @system_load_thresholds.latency_high

    # Take the maximum pressure as the limiting factor
    max(cpu_pressure, max(memory_pressure, latency_pressure))
  end

  # Calculate delay based on backpressure level
  defp calculate_backpressure_delay(pressure_level, config) do
    # Linear scaling from min to max delay based on pressure
    base_delay = config.min_chunk_delay_ms
    max_additional_delay = config.max_chunk_delay_ms - base_delay

    additional_delay = pressure_level * max_additional_delay
    trunc(base_delay + additional_delay)
  end

  # Adjust client rate based on backpressure level
  defp adjust_rate_for_backpressure(client_state, severity, config) do
    case severity do
      :mild ->
        # Reduce rate moderately
        new_rate = client_state.current_rate * config.rate_reduction_factor
        new_rate = max(new_rate, 1.0)  # Minimum 1 chunk per second

        %{client_state |
          current_rate: new_rate,
          backpressure_detected: true,
          rate_adjustments: client_state.rate_adjustments + 1
        }

      :severe ->
        # Reduce rate significantly
        new_rate = client_state.current_rate * 0.25  # Reduce to 25%
        new_rate = max(new_rate, 0.5)  # Minimum 0.5 chunks per second

        %{client_state |
          current_rate: new_rate,
          backpressure_detected: true,
          rate_adjustments: client_state.rate_adjustments + 1
        }
    end
  end

  # Record chunk in client state
  defp record_chunk_in_client_state(client_state, chunk_size, timestamp, config) do
    # Add timestamp to recent chunks
    window_start = timestamp - config.chunk_rate_window_ms
    recent_timestamps = Enum.filter(client_state.chunk_timestamps, &(&1 >= window_start))
    new_timestamps = [timestamp | recent_timestamps]

    # Update client state
    %{client_state |
      last_chunk_time: timestamp,
      chunk_timestamps: new_timestamps,
      total_chunks_sent: client_state.total_chunks_sent + 1,
      total_bytes_sent: client_state.total_bytes_sent + chunk_size
    }
  end

  # Update buffer usage in client state
  defp update_buffer_usage_in_state(client_state, buffer_usage, config) do
    # Check if backpressure state changed
    was_backpressure = client_state.backpressure_detected
    is_backpressure = buffer_usage >= config.backpressure_threshold

    # Adjust rate if backpressure state changed
    new_state = if was_backpressure and not is_backpressure do
      # Backpressure cleared, increase rate
      new_rate = min(
        client_state.current_rate * config.rate_increase_factor,
        client_state.target_rate
      )

      %{client_state |
        current_rate: new_rate,
        backpressure_detected: false
      }
    else
      %{client_state | backpressure_detected: is_backpressure}
    end

    %{new_state | buffer_usage: buffer_usage}
  end

  # Update client state in global state
  defp update_client_state(client_id, client_state, state) do
    new_client_states = Map.put(state.client_states, client_id, client_state)
    %{state | client_states: new_client_states}
  end

  # Update global metrics
  defp update_global_metrics(state, metric_type) do
    case metric_type do
      :chunks_delayed ->
        new_metrics = Map.update!(state.global_metrics, :total_chunks_delayed, &(&1 + 1))
        %{state | global_metrics: new_metrics}

      :backpressure_events ->
        new_metrics = Map.update!(state.global_metrics, :total_backpressure_events, &(&1 + 1))
        %{state | global_metrics: new_metrics}
    end
  end

  # Adjust client rates based on system load
  defp adjust_rates_for_system_load(state) do
    system_pressure = calculate_system_pressure(state.system_load)

    if system_pressure > 0.8 do
      # High system load, reduce all client rates
      Logger.info("High system load detected (#{Float.round(system_pressure, 2)}), reducing client rates")

      adjusted_clients = state.client_states
      |> Enum.map(fn {client_id, client_state} ->
        adjusted_rate = client_state.current_rate * 0.8  # Reduce by 20%
        adjusted_rate = max(adjusted_rate, 0.5)  # Minimum rate

        adjusted_client_state = %{client_state | current_rate: adjusted_rate}
        {client_id, adjusted_client_state}
      end)
      |> Map.new()

      %{state | client_states: adjusted_clients}
    else
      state
    end
  end

  # Build flow state information for client
  defp build_flow_state_info(client_state) do
    current_time = System.monotonic_time(:millisecond)
    recent_chunks = length(client_state.chunk_timestamps)

    %{
      client_id: client_state.client_id,
      current_rate: client_state.current_rate,
      target_rate: client_state.target_rate,
      buffer_usage: client_state.buffer_usage,
      backpressure_detected: client_state.backpressure_detected,
      recent_chunk_count: recent_chunks,
      rate_adjustments: client_state.rate_adjustments,
      total_chunks_sent: client_state.total_chunks_sent,
      total_bytes_sent: client_state.total_bytes_sent,
      last_activity: current_time - client_state.last_chunk_time
    }
  end

  # Build system-wide metrics
  defp build_system_metrics(state) do
    active_clients = map_size(state.client_states)
    total_chunks = state.client_states
    |> Enum.map(fn {_id, client_state} -> client_state.total_chunks_sent end)
    |> Enum.sum()

    total_bytes = state.client_states
    |> Enum.map(fn {_id, client_state} -> client_state.total_bytes_sent end)
    |> Enum.sum()

    clients_with_backpressure = state.client_states
    |> Enum.count(fn {_id, client_state} -> client_state.backpressure_detected end)

    %{
      active_clients: active_clients,
      clients_with_backpressure: clients_with_backpressure,
      total_chunks_sent: total_chunks,
      total_bytes_sent: total_bytes,
      system_load: state.system_load,
      global_metrics: state.global_metrics
    }
  end

  # Schedule periodic system monitoring
  defp schedule_system_monitoring do
    Process.send_after(self(), :system_monitoring, 5000)  # Every 5 seconds
  end

  # Perform system monitoring and cleanup
  defp perform_system_monitoring(state) do
    current_time = System.monotonic_time(:millisecond)

    # Clean up inactive clients (no activity for 5 minutes)
    inactive_threshold = current_time - 300_000  # 5 minutes

    active_clients = state.client_states
    |> Enum.filter(fn {_id, client_state} ->
      client_state.last_chunk_time > inactive_threshold
    end)
    |> Map.new()

    removed_count = map_size(state.client_states) - map_size(active_clients)

    if removed_count > 0 do
      Logger.debug("Cleaned up #{removed_count} inactive clients from backpressure tracking")
    end

    # Update peak concurrent clients metric
    current_clients = map_size(active_clients)
    new_peak = max(current_clients, state.global_metrics.peak_concurrent_clients)

    new_global_metrics = %{state.global_metrics | peak_concurrent_clients: new_peak}

    %{state |
      client_states: active_clients,
      global_metrics: new_global_metrics
    }
  end
end
