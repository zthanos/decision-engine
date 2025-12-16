defmodule DecisionEngine.ReflectionCancellationManager do
  @moduledoc """
  Manages cancellation support and resource cleanup for reflection processes.

  This module provides comprehensive cancellation handling for the agentic reflection pipeline,
  including graceful termination of ongoing processes, proper resource cleanup, and memory
  management to prevent leaks. It coordinates with the ReflectionCoordinator and other
  reflection components to ensure clean shutdown of reflection operations.

  ## Features
  - Cancellation support for ongoing reflection processes
  - Proper resource cleanup on termination
  - Memory management and leak prevention
  - Graceful shutdown coordination with reflection components
  - Timeout handling for stuck processes
  - Resource monitoring and cleanup verification

  ## Usage
      # Register a reflection process for cancellation tracking
      {:ok, cancellation_ref} = ReflectionCancellationManager.register_process(session_id, reflection_pid, options)

      # Cancel a reflection process
      ReflectionCancellationManager.cancel_reflection(cancellation_ref, reason)

      # Check if a process is cancelled
      is_cancelled = ReflectionCancellationManager.is_cancelled?(cancellation_ref)

      # Cleanup resources for a completed process
      ReflectionCancellationManager.cleanup_resources(cancellation_ref)
  """

  use GenServer
  require Logger

  @typedoc """
  Cancellation reference for tracking reflection processes.
  """
  @type cancellation_ref :: reference()

  @typedoc """
  Cancellation status indicators.
  """
  @type cancellation_status :: :active | :cancelling | :cancelled | :completed | :cleanup | :error

  @typedoc """
  Resource types that need cleanup.
  """
  @type resource_type :: :process | :memory | :file | :network | :timer | :monitor

  @typedoc """
  Cancellation configuration options.
  """
  @type cancellation_config :: %{
    session_id: String.t(),
    reflection_pid: pid(),
    timeout_ms: integer(),
    force_kill_timeout_ms: integer(),
    cleanup_timeout_ms: integer(),
    enable_resource_monitoring: boolean(),
    cleanup_callbacks: [function()]
  }

  @typedoc """
  Process state for cancellation tracking.
  """
  @type process_state :: %{
    cancellation_ref: cancellation_ref(),
    session_id: String.t(),
    reflection_pid: pid(),
    config: cancellation_config(),
    status: cancellation_status(),
    start_time: DateTime.t(),
    cancellation_time: DateTime.t() | nil,
    cleanup_time: DateTime.t() | nil,
    resources: %{resource_type() => [term()]},
    monitors: [reference()],
    timers: [reference()],
    cancellation_reason: String.t() | nil,
    cleanup_results: map()
  }

  # Default configuration values
  @default_timeout 30_000  # 30 seconds for graceful shutdown
  @default_force_kill_timeout 10_000  # 10 seconds before force kill
  @default_cleanup_timeout 15_000  # 15 seconds for resource cleanup
  @resource_check_interval 5_000  # 5 seconds between resource checks
  @memory_threshold 100_000_000  # 100MB memory threshold for cleanup

  ## Public API

  @doc """
  Registers a reflection process for cancellation tracking.

  ## Parameters
  - session_id: Unique identifier for the reflection session
  - reflection_pid: Process ID of the reflection coordinator
  - options: Optional configuration for cancellation handling

  ## Returns
  - {:ok, cancellation_ref} on successful registration
  - {:error, reason} if registration fails
  """
  @spec register_process(String.t(), pid(), map()) :: {:ok, cancellation_ref()} | {:error, term()}
  def register_process(session_id, reflection_pid, options \\ %{}) do
    GenServer.call(__MODULE__, {:register_process, session_id, reflection_pid, options})
  end

  @doc """
  Cancels a reflection process with graceful shutdown.

  ## Parameters
  - cancellation_ref: Reference to the process to cancel
  - reason: Optional reason for cancellation

  ## Returns
  - :ok if cancellation initiated successfully
  - {:error, reason} if cancellation fails
  """
  @spec cancel_reflection(cancellation_ref(), String.t()) :: :ok | {:error, term()}
  def cancel_reflection(cancellation_ref, reason \\ "User requested cancellation") do
    GenServer.cast(__MODULE__, {:cancel_reflection, cancellation_ref, reason})
  end

  @doc """
  Checks if a reflection process is cancelled.

  ## Parameters
  - cancellation_ref: Reference to check

  ## Returns
  - true if process is cancelled or being cancelled
  - false if process is still active
  - {:error, :not_found} if reference not found
  """
  @spec is_cancelled?(cancellation_ref()) :: boolean() | {:error, :not_found}
  def is_cancelled?(cancellation_ref) do
    GenServer.call(__MODULE__, {:is_cancelled, cancellation_ref})
  end

  @doc """
  Forces immediate termination of a reflection process.

  This should only be used when graceful cancellation fails.

  ## Parameters
  - cancellation_ref: Reference to the process to force kill
  - reason: Reason for force termination

  ## Returns
  - :ok if force termination successful
  - {:error, reason} if force termination fails
  """
  @spec force_terminate(cancellation_ref(), String.t()) :: :ok | {:error, term()}
  def force_terminate(cancellation_ref, reason \\ "Force termination requested") do
    GenServer.cast(__MODULE__, {:force_terminate, cancellation_ref, reason})
  end

  @doc """
  Manually triggers resource cleanup for a process.

  ## Parameters
  - cancellation_ref: Reference to the process to cleanup

  ## Returns
  - :ok if cleanup initiated
  - {:error, reason} if cleanup fails
  """
  @spec cleanup_resources(cancellation_ref()) :: :ok | {:error, term()}
  def cleanup_resources(cancellation_ref) do
    GenServer.cast(__MODULE__, {:cleanup_resources, cancellation_ref})
  end

  @doc """
  Registers a resource for cleanup tracking.

  ## Parameters
  - cancellation_ref: Reference to associate resource with
  - resource_type: Type of resource (process, memory, file, etc.)
  - resource_data: Resource-specific data for cleanup

  ## Returns
  - :ok if resource registered
  - {:error, reason} if registration fails
  """
  @spec register_resource(cancellation_ref(), resource_type(), term()) :: :ok | {:error, term()}
  def register_resource(cancellation_ref, resource_type, resource_data) do
    GenServer.cast(__MODULE__, {:register_resource, cancellation_ref, resource_type, resource_data})
  end

  @doc """
  Gets the current status of a cancellation process.

  ## Parameters
  - cancellation_ref: Reference to check

  ## Returns
  - {:ok, status_info} if process exists
  - {:error, :not_found} if process not found
  """
  @spec get_cancellation_status(cancellation_ref()) :: {:ok, map()} | {:error, :not_found}
  def get_cancellation_status(cancellation_ref) do
    GenServer.call(__MODULE__, {:get_cancellation_status, cancellation_ref})
  end

  @doc """
  Lists all active cancellation processes.

  ## Returns
  - List of {cancellation_ref, session_id, status} tuples
  """
  @spec list_active_processes() :: [{cancellation_ref(), String.t(), cancellation_status()}]
  def list_active_processes() do
    GenServer.call(__MODULE__, :list_active_processes)
  end

  @doc """
  Starts the ReflectionCancellationManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize state with empty process tracking
    state = %{
      processes: %{},  # cancellation_ref -> process_state
      session_to_ref: %{},  # session_id -> cancellation_ref
      pid_to_ref: %{}  # pid -> cancellation_ref
    }

    # Schedule periodic resource monitoring
    schedule_resource_monitoring()

    Logger.info("ReflectionCancellationManager started")
    {:ok, state}
  end

  @impl true
  def handle_call({:register_process, session_id, reflection_pid, options}, _from, state) do
    Logger.info("Registering reflection process for cancellation tracking: #{session_id}")

    # Generate unique cancellation reference
    cancellation_ref = make_ref()

    # Create cancellation configuration
    cancellation_config = %{
      session_id: session_id,
      reflection_pid: reflection_pid,
      timeout_ms: Map.get(options, :timeout_ms, @default_timeout),
      force_kill_timeout_ms: Map.get(options, :force_kill_timeout_ms, @default_force_kill_timeout),
      cleanup_timeout_ms: Map.get(options, :cleanup_timeout_ms, @default_cleanup_timeout),
      enable_resource_monitoring: Map.get(options, :enable_resource_monitoring, true),
      cleanup_callbacks: Map.get(options, :cleanup_callbacks, [])
    }

    # Monitor the reflection process
    monitor_ref = Process.monitor(reflection_pid)

    # Initialize process state
    process_state = %{
      cancellation_ref: cancellation_ref,
      session_id: session_id,
      reflection_pid: reflection_pid,
      config: cancellation_config,
      status: :active,
      start_time: DateTime.utc_now(),
      cancellation_time: nil,
      cleanup_time: nil,
      resources: %{},
      monitors: [monitor_ref],
      timers: [],
      cancellation_reason: nil,
      cleanup_results: %{}
    }

    # Update state
    new_state = %{state |
      processes: Map.put(state.processes, cancellation_ref, process_state),
      session_to_ref: Map.put(state.session_to_ref, session_id, cancellation_ref),
      pid_to_ref: Map.put(state.pid_to_ref, reflection_pid, cancellation_ref)
    }

    {:reply, {:ok, cancellation_ref}, new_state}
  end

  @impl true
  def handle_call({:is_cancelled, cancellation_ref}, _from, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil -> {:reply, {:error, :not_found}, state}
      process_state ->
        is_cancelled = process_state.status in [:cancelling, :cancelled, :cleanup]
        {:reply, is_cancelled, state}
    end
  end

  @impl true
  def handle_call({:get_cancellation_status, cancellation_ref}, _from, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil -> {:reply, {:error, :not_found}, state}
      process_state ->
        status_info = %{
          session_id: process_state.session_id,
          status: process_state.status,
          start_time: process_state.start_time,
          cancellation_time: process_state.cancellation_time,
          cleanup_time: process_state.cleanup_time,
          cancellation_reason: process_state.cancellation_reason,
          resource_count: count_resources(process_state.resources),
          cleanup_results: process_state.cleanup_results
        }
        {:reply, {:ok, status_info}, state}
    end
  end

  @impl true
  def handle_call(:list_active_processes, _from, state) do
    active_processes = state.processes
    |> Enum.map(fn {cancellation_ref, process_state} ->
      {cancellation_ref, process_state.session_id, process_state.status}
    end)

    {:reply, active_processes, state}
  end

  @impl true
  def handle_cast({:cancel_reflection, cancellation_ref, reason}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        Logger.warning("Cancellation request for unknown process: #{inspect(cancellation_ref)}")
        {:noreply, state}

      process_state ->
        if process_state.status == :active do
          Logger.info("Initiating graceful cancellation for session: #{process_state.session_id}, reason: #{reason}")

          # Update process state
          updated_process_state = %{process_state |
            status: :cancelling,
            cancellation_time: DateTime.utc_now(),
            cancellation_reason: reason
          }

          new_state = %{state |
            processes: Map.put(state.processes, cancellation_ref, updated_process_state)
          }

          # Start graceful cancellation process
          start_graceful_cancellation(updated_process_state)

          {:noreply, new_state}
        else
          Logger.debug("Cancellation request for already cancelled/completed process: #{process_state.session_id}")
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:force_terminate, cancellation_ref, reason}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        Logger.warning("Force termination request for unknown process: #{inspect(cancellation_ref)}")
        {:noreply, state}

      process_state ->
        Logger.warning("Force terminating reflection process for session: #{process_state.session_id}, reason: #{reason}")

        # Kill the process immediately
        Process.exit(process_state.reflection_pid, :kill)

        # Update process state
        updated_process_state = %{process_state |
          status: :cancelled,
          cancellation_time: process_state.cancellation_time || DateTime.utc_now(),
          cancellation_reason: reason
        }

        new_state = %{state |
          processes: Map.put(state.processes, cancellation_ref, updated_process_state)
        }

        # Start immediate cleanup
        start_resource_cleanup(updated_process_state)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:cleanup_resources, cancellation_ref}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        Logger.warning("Cleanup request for unknown process: #{inspect(cancellation_ref)}")
        {:noreply, state}

      process_state ->
        Logger.info("Starting manual resource cleanup for session: #{process_state.session_id}")

        # Update process state
        updated_process_state = %{process_state |
          status: :cleanup,
          cleanup_time: DateTime.utc_now()
        }

        new_state = %{state |
          processes: Map.put(state.processes, cancellation_ref, updated_process_state)
        }

        # Start cleanup process
        start_resource_cleanup(updated_process_state)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:register_resource, cancellation_ref, resource_type, resource_data}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        Logger.warning("Resource registration for unknown process: #{inspect(cancellation_ref)}")
        {:noreply, state}

      process_state ->
        # Add resource to tracking
        current_resources = Map.get(process_state.resources, resource_type, [])
        updated_resources = Map.put(process_state.resources, resource_type, [resource_data | current_resources])

        updated_process_state = %{process_state | resources: updated_resources}

        new_state = %{state |
          processes: Map.put(state.processes, cancellation_ref, updated_process_state)
        }

        Logger.debug("Registered #{resource_type} resource for session: #{process_state.session_id}")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.get(state.pid_to_ref, pid) do
      nil ->
        # Process not tracked by us
        {:noreply, state}

      cancellation_ref ->
        case Map.get(state.processes, cancellation_ref) do
          nil ->
            {:noreply, state}

          process_state ->
            Logger.info("Reflection process terminated for session: #{process_state.session_id}, reason: #{inspect(reason)}")

            # Update process state based on termination reason
            status = case reason do
              :normal -> :completed
              :shutdown -> :completed
              {:shutdown, _} -> :completed
              _ -> :cancelled
            end

            updated_process_state = %{process_state |
              status: status,
              cleanup_time: DateTime.utc_now()
            }

            new_state = %{state |
              processes: Map.put(state.processes, cancellation_ref, updated_process_state)
            }

            # Start cleanup process
            start_resource_cleanup(updated_process_state)

            {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info({:graceful_timeout, cancellation_ref}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        {:noreply, state}

      process_state ->
        if process_state.status == :cancelling do
          Logger.warning("Graceful cancellation timeout for session: #{process_state.session_id}, forcing termination")

          # Force kill the process
          Process.exit(process_state.reflection_pid, :kill)

          # Update status
          updated_process_state = %{process_state | status: :cancelled}

          new_state = %{state |
            processes: Map.put(state.processes, cancellation_ref, updated_process_state)
          }

          {:noreply, new_state}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:cleanup_complete, cancellation_ref, cleanup_results}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        {:noreply, state}

      process_state ->
        Logger.info("Resource cleanup completed for session: #{process_state.session_id}")

        # Update cleanup results
        updated_process_state = %{process_state |
          cleanup_results: cleanup_results,
          status: if(process_state.status == :cleanup, do: :completed, else: process_state.status)
        }

        new_state = %{state |
          processes: Map.put(state.processes, cancellation_ref, updated_process_state)
        }

        # Schedule final cleanup after delay
        Process.send_after(self(), {:final_cleanup, cancellation_ref}, 5000)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:final_cleanup, cancellation_ref}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        {:noreply, state}

      process_state ->
        Logger.debug("Final cleanup for session: #{process_state.session_id}")

        # Remove from all tracking maps
        new_state = %{state |
          processes: Map.delete(state.processes, cancellation_ref),
          session_to_ref: Map.delete(state.session_to_ref, process_state.session_id),
          pid_to_ref: Map.delete(state.pid_to_ref, process_state.reflection_pid)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:cleanup_timeout, cancellation_ref, cleanup_pid}, state) do
    case Map.get(state.processes, cancellation_ref) do
      nil ->
        {:noreply, state}

      process_state ->
        Logger.warning("Cleanup timeout for session: #{process_state.session_id}, forcing cleanup completion")

        # Kill the cleanup process if it's still running
        if Process.alive?(cleanup_pid) do
          Process.exit(cleanup_pid, :kill)
        end

        # Mark cleanup as completed with timeout
        updated_process_state = %{process_state |
          cleanup_results: %{timeout: true, message: "Cleanup timed out"},
          status: :completed
        }

        new_state = %{state |
          processes: Map.put(state.processes, cancellation_ref, updated_process_state)
        }

        # Schedule final cleanup
        Process.send_after(self(), {:final_cleanup, cancellation_ref}, 1000)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:resource_monitoring, state) do
    # Perform resource monitoring for all active processes
    perform_resource_monitoring(state)

    # Schedule next monitoring cycle
    schedule_resource_monitoring()

    {:noreply, state}
  end

  ## Private Functions

  defp start_graceful_cancellation(process_state) do
    # Send cancellation signal to the reflection process
    send(process_state.reflection_pid, {:cancel_reflection, process_state.cancellation_reason})

    # Set timeout for graceful cancellation
    Process.send_after(self(), {:graceful_timeout, process_state.cancellation_ref}, process_state.config.timeout_ms)
  end

  defp start_resource_cleanup(process_state) do
    # Spawn cleanup process to avoid blocking
    cleanup_pid = spawn_link(fn ->
      cleanup_results = perform_resource_cleanup(process_state)
      send(self(), {:cleanup_complete, process_state.cancellation_ref, cleanup_results})
    end)

    # Set timeout for cleanup process
    Process.send_after(self(), {:cleanup_timeout, process_state.cancellation_ref, cleanup_pid}, process_state.config.cleanup_timeout_ms)
  end

  defp perform_resource_cleanup(process_state) do
    Logger.debug("Performing resource cleanup for session: #{process_state.session_id}")

    cleanup_results = %{}

    # Cleanup different resource types
    cleanup_results = cleanup_results
    |> Map.put(:processes, cleanup_process_resources(process_state.resources[:process] || []))
    |> Map.put(:memory, cleanup_memory_resources(process_state.resources[:memory] || []))
    |> Map.put(:files, cleanup_file_resources(process_state.resources[:file] || []))
    |> Map.put(:network, cleanup_network_resources(process_state.resources[:network] || []))
    |> Map.put(:timers, cleanup_timer_resources(process_state.resources[:timer] || []))
    |> Map.put(:monitors, cleanup_monitor_resources(process_state.monitors))

    # Execute custom cleanup callbacks
    callback_results = execute_cleanup_callbacks(process_state.config.cleanup_callbacks)
    Map.put(cleanup_results, :callbacks, callback_results)
  end

  defp cleanup_process_resources(process_resources) do
    Enum.map(process_resources, fn pid ->
      try do
        if Process.alive?(pid) do
          Process.exit(pid, :shutdown)
          {:ok, pid}
        else
          {:already_dead, pid}
        end
      rescue
        error -> {:error, pid, error}
      end
    end)
  end

  defp cleanup_memory_resources(memory_resources) do
    # Force garbage collection and memory cleanup
    :erlang.garbage_collect()

    Enum.map(memory_resources, fn resource ->
      try do
        # Attempt to clean up memory resource (implementation depends on resource type)
        case resource do
          {:ets, table_id} ->
            if :ets.info(table_id) != :undefined do
              :ets.delete(table_id)
              {:ok, table_id}
            else
              {:already_deleted, table_id}
            end

          {:large_binary, _ref} ->
            # Large binaries are handled by garbage collection
            {:ok, :gc_handled}

          _ ->
            {:unknown_resource, resource}
        end
      rescue
        error -> {:error, resource, error}
      end
    end)
  end

  defp cleanup_file_resources(file_resources) do
    Enum.map(file_resources, fn file_path ->
      try do
        if File.exists?(file_path) do
          File.rm(file_path)
          {:ok, file_path}
        else
          {:not_found, file_path}
        end
      rescue
        error -> {:error, file_path, error}
      end
    end)
  end

  defp cleanup_network_resources(network_resources) do
    Enum.map(network_resources, fn resource ->
      try do
        case resource do
          {:socket, socket} ->
            :gen_tcp.close(socket)
            {:ok, socket}

          {:http_connection, conn} ->
            # Close HTTP connection (implementation depends on HTTP client)
            {:ok, conn}

          _ ->
            {:unknown_resource, resource}
        end
      rescue
        error -> {:error, resource, error}
      end
    end)
  end

  defp cleanup_timer_resources(timer_resources) do
    Enum.map(timer_resources, fn timer_ref ->
      try do
        Process.cancel_timer(timer_ref)
        {:ok, timer_ref}
      rescue
        error -> {:error, timer_ref, error}
      end
    end)
  end

  defp cleanup_monitor_resources(monitor_refs) do
    Enum.map(monitor_refs, fn monitor_ref ->
      try do
        Process.demonitor(monitor_ref, [:flush])
        {:ok, monitor_ref}
      rescue
        error -> {:error, monitor_ref, error}
      end
    end)
  end

  defp execute_cleanup_callbacks(callbacks) do
    Enum.map(callbacks, fn callback ->
      try do
        result = callback.()
        {:ok, result}
      rescue
        error -> {:error, error}
      end
    end)
  end

  defp perform_resource_monitoring(state) do
    # Check memory usage for all active processes
    total_memory = :erlang.memory(:total)

    if total_memory > @memory_threshold do
      Logger.warning("High memory usage detected: #{total_memory} bytes")

      # Trigger garbage collection for all processes
      state.processes
      |> Enum.each(fn {_ref, process_state} ->
        if Process.alive?(process_state.reflection_pid) do
          send(process_state.reflection_pid, :garbage_collect)
        end
      end)
    end
  end

  defp schedule_resource_monitoring do
    Process.send_after(self(), :resource_monitoring, @resource_check_interval)
  end

  defp count_resources(resources) do
    resources
    |> Enum.map(fn {_type, resource_list} -> length(resource_list) end)
    |> Enum.sum()
  end
end
