defmodule DecisionEngine.ReflectionQueueManager do
  @moduledoc """
  Manages concurrent processing of reflection requests with queue management and resource isolation.

  This module provides non-blocking reflection processing by managing a queue of reflection
  requests and processing them concurrently while respecting system resource constraints.
  It ensures that multiple reflection requests can be processed simultaneously without
  blocking other system operations.

  ## Features
  - Non-blocking reflection request queuing
  - Concurrent processing with configurable limits
  - Resource sharing and isolation mechanisms
  - Priority-based queue management
  - Automatic load balancing and throttling
  - Comprehensive monitoring and metrics

  ## Usage
      # Queue a reflection request
      {:ok, request_id} = ReflectionQueueManager.queue_reflection(domain_config, options)

      # Check queue status
      status = ReflectionQueueManager.get_queue_status()

      # Cancel a queued request
      ReflectionQueueManager.cancel_request(request_id)
  """

  use GenServer
  require Logger

  alias DecisionEngine.ReflectionCoordinator
  alias DecisionEngine.ReflectionPerformanceMonitor
  alias DecisionEngine.ReflectionConfig

  @typedoc """
  Unique identifier for a reflection request.
  """
  @type request_id :: String.t()

  @typedoc """
  Priority levels for reflection requests.
  """
  @type priority :: :low | :normal | :high | :urgent

  @typedoc """
  Status of a reflection request in the queue.
  """
  @type request_status :: :queued | :processing | :completed | :failed | :cancelled

  @typedoc """
  Reflection request structure.
  """
  @type reflection_request :: %{
    request_id: request_id(),
    domain_config: map(),
    options: map(),
    priority: priority(),
    queued_at: DateTime.t(),
    started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil,
    callback_pid: pid() | nil,
    session_id: String.t() | nil,
    status: request_status(),
    worker_pid: pid() | nil,
    result: term() | nil,
    error: term() | nil
  }

  @typedoc """
  Queue manager state.
  """
  @type state :: %{
    queue: :queue.queue(reflection_request()),
    processing: %{pid() => reflection_request()},
    completed: %{request_id() => reflection_request()},
    max_concurrent: non_neg_integer(),
    current_load: non_neg_integer(),
    total_processed: non_neg_integer(),
    total_failed: non_neg_integer(),
    start_time: DateTime.t(),
    config: map()
  }

  # Default configuration
  @default_max_concurrent 3
  @default_queue_timeout 300_000  # 5 minutes
  @default_result_retention 3600_000  # 1 hour
  @cleanup_interval 60_000  # 1 minute

  ## Public API

  @doc """
  Starts the ReflectionQueueManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queues a reflection request for processing.

  ## Parameters
  - domain_config: The domain configuration to reflect upon
  - options: Reflection options including priority, callback_pid, session_id

  ## Returns
  - {:ok, request_id} if request queued successfully
  - {:error, reason} if queueing fails

  ## Options
  - priority: :low | :normal | :high | :urgent (default: :normal)
  - callback_pid: Process to receive completion notifications
  - session_id: Optional session identifier for tracking
  - timeout: Request-specific timeout (default: system default)
  """
  @spec queue_reflection(map(), map()) :: {:ok, request_id()} | {:error, term()}
  def queue_reflection(domain_config, options \\ %{}) do
    GenServer.call(__MODULE__, {:queue_reflection, domain_config, options})
  end

  @doc """
  Gets the status of a specific reflection request.

  ## Parameters
  - request_id: The request identifier

  ## Returns
  - {:ok, reflection_request()} if request found
  - {:error, :not_found} if request not found
  """
  @spec get_request_status(request_id()) :: {:ok, reflection_request()} | {:error, :not_found}
  def get_request_status(request_id) do
    GenServer.call(__MODULE__, {:get_request_status, request_id})
  end

  @doc """
  Cancels a queued or processing reflection request.

  ## Parameters
  - request_id: The request identifier to cancel

  ## Returns
  - :ok if cancellation initiated
  - {:error, reason} if cancellation fails
  """
  @spec cancel_request(request_id()) :: :ok | {:error, term()}
  def cancel_request(request_id) do
    GenServer.call(__MODULE__, {:cancel_request, request_id})
  end

  @doc """
  Gets the current queue status and metrics.

  ## Returns
  - Map containing queue statistics and current load information
  """
  @spec get_queue_status() :: map()
  def get_queue_status() do
    GenServer.call(__MODULE__, :get_queue_status)
  end

  @doc """
  Lists all active (queued or processing) reflection requests.

  ## Returns
  - List of reflection_request() structures for active requests
  """
  @spec list_active_requests() :: [reflection_request()]
  def list_active_requests() do
    GenServer.call(__MODULE__, :list_active_requests)
  end

  @doc """
  Updates the queue configuration.

  ## Parameters
  - config: Map containing configuration updates

  ## Returns
  - :ok if configuration updated successfully
  - {:error, reason} if update fails

  ## Configuration Options
  - max_concurrent: Maximum number of concurrent reflection processes
  - queue_timeout: Default timeout for queued requests
  - result_retention: How long to retain completed results
  """
  @spec update_config(map()) :: :ok | {:error, term()}
  def update_config(config) do
    GenServer.call(__MODULE__, {:update_config, config})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Load configuration
    config = load_queue_config(opts)

    state = %{
      queue: :queue.new(),
      processing: %{},
      completed: %{},
      max_concurrent: Map.get(config, :max_concurrent, @default_max_concurrent),
      current_load: 0,
      total_processed: 0,
      total_failed: 0,
      start_time: DateTime.utc_now(),
      config: config
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("ReflectionQueueManager started with max_concurrent: #{state.max_concurrent}")
    {:ok, state}
  end

  @impl true
  def handle_call({:queue_reflection, domain_config, options}, _from, state) do
    # Generate unique request ID
    request_id = generate_request_id(domain_config, options)

    # Validate domain configuration
    case validate_domain_config(domain_config) do
      :ok ->
        # Create reflection request
        request = create_reflection_request(request_id, domain_config, options)

        # Add to queue based on priority
        new_queue = add_to_queue(state.queue, request)
        new_state = %{state | queue: new_queue}

        Logger.info("Queued reflection request #{request_id} with priority #{request.priority}")

        # Try to process immediately if capacity available
        final_state = try_process_next(new_state)

        {:reply, {:ok, request_id}, final_state}

      {:error, reason} ->
        Logger.error("Invalid domain configuration for reflection: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_request_status, request_id}, _from, state) do
    # Check in processing
    processing_request = state.processing
    |> Enum.find_value(fn {_pid, request} ->
      if request.request_id == request_id, do: request, else: nil
    end)

    if processing_request do
      {:reply, {:ok, processing_request}, state}
    else
      # Check in completed
      case Map.get(state.completed, request_id) do
        nil ->
          # Check in queue
          queue_request = :queue.to_list(state.queue)
          |> Enum.find(fn request -> request.request_id == request_id end)

          if queue_request do
            {:reply, {:ok, queue_request}, state}
          else
            {:reply, {:error, :not_found}, state}
          end

        completed_request ->
          {:reply, {:ok, completed_request}, state}
      end
    end
  end

  @impl true
  def handle_call({:cancel_request, request_id}, _from, state) do
    # Try to cancel from queue first
    {new_queue, found_in_queue} = remove_from_queue(state.queue, request_id)

    if found_in_queue do
      Logger.info("Cancelled queued reflection request #{request_id}")
      {:reply, :ok, %{state | queue: new_queue}}
    else
      # Try to cancel from processing
      processing_request = state.processing
      |> Enum.find_value(fn {pid, request} ->
        if request.request_id == request_id, do: {pid, request}, else: nil
      end)

      case processing_request do
        {worker_pid, request} ->
          Logger.info("Cancelling processing reflection request #{request_id}")

          # Terminate the worker process
          Process.exit(worker_pid, :cancelled)

          # Update request status
          cancelled_request = %{request |
            status: :cancelled,
            completed_at: DateTime.utc_now(),
            error: "Request cancelled by user"
          }

          # Move to completed and remove from processing
          new_state = %{state |
            processing: Map.delete(state.processing, worker_pid),
            completed: Map.put(state.completed, request_id, cancelled_request),
            current_load: state.current_load - 1
          }

          # Notify callback if present
          if request.callback_pid do
            send_completion_notification(request.callback_pid, cancelled_request)
          end

          # Try to process next request
          final_state = try_process_next(new_state)

          {:reply, :ok, final_state}

        nil ->
          {:reply, {:error, :not_found}, state}
      end
    end
  end

  @impl true
  def handle_call(:get_queue_status, _from, state) do
    queue_length = :queue.len(state.queue)
    processing_count = map_size(state.processing)

    # Calculate queue statistics by priority
    queue_stats = :queue.to_list(state.queue)
    |> Enum.group_by(& &1.priority)
    |> Enum.map(fn {priority, requests} -> {priority, length(requests)} end)
    |> Enum.into(%{})

    # Calculate average processing time from completed requests
    avg_processing_time = calculate_average_processing_time(state.completed)

    status = %{
      queue_length: queue_length,
      processing_count: processing_count,
      current_load: state.current_load,
      max_concurrent: state.max_concurrent,
      total_processed: state.total_processed,
      total_failed: state.total_failed,
      queue_stats_by_priority: queue_stats,
      average_processing_time_ms: avg_processing_time,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.start_time, :second),
      system_load: get_system_load_info()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:list_active_requests, _from, state) do
    queued_requests = :queue.to_list(state.queue)
    processing_requests = Map.values(state.processing)

    active_requests = queued_requests ++ processing_requests
    {:reply, active_requests, state}
  end

  @impl true
  def handle_call({:update_config, config}, _from, state) do
    case validate_queue_config(config) do
      :ok ->
        new_config = Map.merge(state.config, config)
        new_max_concurrent = Map.get(config, :max_concurrent, state.max_concurrent)

        new_state = %{state |
          config: new_config,
          max_concurrent: new_max_concurrent
        }

        Logger.info("Updated queue configuration: max_concurrent=#{new_max_concurrent}")

        # Try to process more requests if capacity increased
        final_state = if new_max_concurrent > state.max_concurrent do
          try_process_next(new_state)
        else
          new_state
        end

        {:reply, :ok, final_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
    case Map.get(state.processing, worker_pid) do
      nil ->
        # Unknown worker process
        {:noreply, state}

      request ->
        Logger.info("Reflection worker #{inspect(worker_pid)} terminated: #{inspect(reason)}")

        # Determine completion status based on termination reason
        {status, result, error} = case reason do
          :normal -> {:completed, request.result, nil}
          :cancelled -> {:cancelled, nil, "Request cancelled"}
          _ -> {:failed, nil, "Worker process terminated: #{inspect(reason)}"}
        end

        # Update request with completion info
        completed_request = %{request |
          status: status,
          completed_at: DateTime.utc_now(),
          result: result,
          error: error,
          worker_pid: nil
        }

        # Update state
        new_state = %{state |
          processing: Map.delete(state.processing, worker_pid),
          completed: Map.put(state.completed, request.request_id, completed_request),
          current_load: state.current_load - 1,
          total_processed: if(status == :completed, do: state.total_processed + 1, else: state.total_processed),
          total_failed: if(status == :failed, do: state.total_failed + 1, else: state.total_failed)
        }

        # Notify callback if present
        if request.callback_pid do
          send_completion_notification(request.callback_pid, completed_request)
        end

        # Try to process next request
        final_state = try_process_next(new_state)

        {:noreply, final_state}
    end
  end

  @impl true
  def handle_info({:reflection_result, worker_pid, result}, state) do
    case Map.get(state.processing, worker_pid) do
      nil ->
        Logger.warning("Received result from unknown worker: #{inspect(worker_pid)}")
        {:noreply, state}

      request ->
        # Update request with result
        updated_request = %{request | result: result}
        new_processing = Map.put(state.processing, worker_pid, updated_request)

        {:noreply, %{state | processing: new_processing}}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean up old completed requests
    cutoff_time = DateTime.add(DateTime.utc_now(), -@default_result_retention, :millisecond)

    new_completed = state.completed
    |> Enum.filter(fn {_id, request} ->
      DateTime.compare(request.completed_at || DateTime.utc_now(), cutoff_time) == :gt
    end)
    |> Enum.into(%{})

    cleaned_count = map_size(state.completed) - map_size(new_completed)

    if cleaned_count > 0 do
      Logger.debug("Cleaned up #{cleaned_count} old reflection results")
    end

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, %{state | completed: new_completed}}
  end

  ## Private Functions

  defp load_queue_config(opts) do
    # Load from system configuration or use defaults
    case ReflectionConfig.get_current_config() do
      {:ok, reflection_config} ->
        %{
          max_concurrent: Map.get(reflection_config, :max_concurrent_reflections, @default_max_concurrent),
          queue_timeout: Map.get(reflection_config, :queue_timeout_ms, @default_queue_timeout),
          result_retention: Map.get(reflection_config, :result_retention_ms, @default_result_retention)
        }

      {:error, _} ->
        %{
          max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
          queue_timeout: Keyword.get(opts, :queue_timeout, @default_queue_timeout),
          result_retention: Keyword.get(opts, :result_retention, @default_result_retention)
        }
    end
  end

  defp validate_domain_config(domain_config) when is_map(domain_config) do
    # Basic validation - ensure required fields are present
    required_fields = ["domain", "patterns"]

    missing_fields = required_fields
    |> Enum.filter(fn field -> not Map.has_key?(domain_config, field) end)

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  defp validate_domain_config(_), do: {:error, "Domain configuration must be a map"}

  defp validate_queue_config(config) do
    # Validate configuration parameters
    with :ok <- validate_max_concurrent(Map.get(config, :max_concurrent)),
         :ok <- validate_timeout(Map.get(config, :queue_timeout)),
         :ok <- validate_timeout(Map.get(config, :result_retention)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_max_concurrent(nil), do: :ok
  defp validate_max_concurrent(max) when is_integer(max) and max > 0 and max <= 10, do: :ok
  defp validate_max_concurrent(max), do: {:error, "max_concurrent must be between 1 and 10, got #{max}"}

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(timeout), do: {:error, "timeout must be a positive integer, got #{timeout}"}

  defp generate_request_id(domain_config, options) do
    domain_name = Map.get(domain_config, "domain", "unknown")
    session_id = Map.get(options, :session_id, "")
    timestamp = System.system_time(:microsecond)
    "reflection_#{domain_name}_#{session_id}_#{timestamp}"
  end

  defp create_reflection_request(request_id, domain_config, options) do
    %{
      request_id: request_id,
      domain_config: domain_config,
      options: options,
      priority: Map.get(options, :priority, :normal),
      queued_at: DateTime.utc_now(),
      started_at: nil,
      completed_at: nil,
      callback_pid: Map.get(options, :callback_pid),
      session_id: Map.get(options, :session_id),
      status: :queued,
      worker_pid: nil,
      result: nil,
      error: nil
    }
  end

  defp add_to_queue(queue, request) do
    # Add request to queue based on priority
    # Higher priority requests are processed first
    case request.priority do
      :urgent -> :queue.in_r(request, queue)  # Add to front
      :high -> :queue.in_r(request, queue)    # Add to front
      _ -> :queue.in(request, queue)          # Add to back (normal, low)
    end
  end

  defp remove_from_queue(queue, request_id) do
    queue_list = :queue.to_list(queue)

    case Enum.find_index(queue_list, fn req -> req.request_id == request_id end) do
      nil ->
        {queue, false}

      index ->
        new_list = List.delete_at(queue_list, index)
        new_queue = :queue.from_list(new_list)
        {new_queue, true}
    end
  end

  defp try_process_next(state) do
    if state.current_load < state.max_concurrent and not :queue.is_empty(state.queue) do
      {{:value, request}, new_queue} = :queue.out(state.queue)

      # Start reflection worker
      case start_reflection_worker(request) do
        {:ok, worker_pid} ->
          # Monitor the worker process
          Process.monitor(worker_pid)

          # Update request and state
          processing_request = %{request |
            status: :processing,
            started_at: DateTime.utc_now(),
            worker_pid: worker_pid
          }

          new_state = %{state |
            queue: new_queue,
            processing: Map.put(state.processing, worker_pid, processing_request),
            current_load: state.current_load + 1
          }

          Logger.info("Started reflection worker for request #{request.request_id}")

          # Try to process more if capacity allows
          try_process_next(new_state)

        # start_reflection_worker always returns {:ok, pid()}, so this clause is not needed
        # but keeping it for future extensibility
      end
    else
      state
    end
  end

  defp start_reflection_worker(request) do
    # Start a new process to handle the reflection
    parent_pid = self()

    worker_pid = spawn_link(fn ->
      Logger.debug("Starting reflection processing for request #{request.request_id}")

      try do
        # Perform the actual reflection
        case ReflectionCoordinator.start_reflection(request.domain_config, request.options) do
          {:ok, result} ->
            # Send result back to queue manager
            send(parent_pid, {:reflection_result, self(), result})
            Logger.debug("Reflection completed successfully for request #{request.request_id}")

          {:error, reason} ->
            Logger.error("Reflection failed for request #{request.request_id}: #{inspect(reason)}")
            exit({:reflection_error, reason})

          {:cancelled, reason} ->
            Logger.info("Reflection cancelled for request #{request.request_id}: #{reason}")
            exit({:reflection_cancelled, reason})
        end
      rescue
        error ->
          Logger.error("Reflection worker crashed for request #{request.request_id}: #{inspect(error)}")
          exit({:reflection_crash, error})
      end
    end)

    {:ok, worker_pid}
  end

  defp send_completion_notification(callback_pid, request) do
    notification = case request.status do
      :completed ->
        {:reflection_completed, request.request_id, request.result}

      :failed ->
        {:reflection_failed, request.request_id, request.error}

      :cancelled ->
        {:reflection_cancelled, request.request_id, request.error}
    end

    send(callback_pid, notification)
  end

  defp calculate_average_processing_time(completed_requests) do
    processing_times = completed_requests
    |> Map.values()
    |> Enum.filter(fn req -> req.started_at && req.completed_at end)
    |> Enum.map(fn req ->
      DateTime.diff(req.completed_at, req.started_at, :millisecond)
    end)

    case processing_times do
      [] -> 0
      times -> Enum.sum(times) / length(times)
    end
  end

  defp get_system_load_info() do
    # Get basic system load information
    %{
      memory_usage: :erlang.memory(:total),
      process_count: :erlang.system_info(:process_count),
      scheduler_utilization: get_scheduler_utilization()
    }
  end

  defp get_scheduler_utilization() do
    # Simplified scheduler utilization check
    case :scheduler.sample_all() do
      schedulers when is_list(schedulers) ->
        total_util = schedulers
        |> Enum.map(fn {_id, util, _} -> util end)
        |> Enum.sum()

        total_util / length(schedulers)

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  defp schedule_cleanup() do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
