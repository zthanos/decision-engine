defmodule DecisionEngine.ReflectionProgressTracker do
  @moduledoc """
  Manages real-time progress tracking for reflection processes.

  This module provides comprehensive progress tracking for the agentic reflection pipeline,
  including stage tracking, completion time estimation, and progress message broadcasting
  to UI components. It integrates with the existing streaming infrastructure to provide
  seamless progress updates during reflection operations.

  ## Features
  - Real-time progress updates during reflection
  - Stage tracking with detailed descriptions
  - Completion time estimation based on historical data
  - Progress message broadcasting to UI
  - Integration with existing StreamManager and SSE infrastructure
  - Cancellation support for ongoing reflection processes

  ## Usage
      # Start progress tracking for a reflection session
      {:ok, tracker_ref} = ReflectionProgressTracker.start_tracking(session_id, stream_pid, options)

      # Update progress for a specific stage
      ReflectionProgressTracker.update_progress(tracker_ref, :evaluation, 25, "Evaluating domain configuration quality")

      # Complete progress tracking
      ReflectionProgressTracker.complete_tracking(tracker_ref, result)

      # Cancel progress tracking
      ReflectionProgressTracker.cancel_tracking(tracker_ref)
  """

  use GenServer
  require Logger

  @typedoc """
  Progress tracker reference for tracking active reflection sessions.
  """
  @type tracker_ref :: reference()

  @typedoc """
  Reflection stage identifiers.
  """
  @type reflection_stage ::
    :initializing | :evaluation | :feedback_generation | :refinement |
    :validation | :iteration_check | :finalizing | :completed | :cancelled | :error

  @typedoc """
  Progress tracking configuration.
  """
  @type progress_config :: %{
    session_id: String.t(),
    stream_pid: pid(),
    max_iterations: integer(),
    enable_time_estimation: boolean(),
    progress_interval_ms: integer(),
    detailed_logging: boolean()
  }

  @typedoc """
  Progress state for internal tracking.
  """
  @type progress_state :: %{
    tracker_ref: tracker_ref(),
    session_id: String.t(),
    stream_pid: pid(),
    config: progress_config(),
    current_stage: reflection_stage(),
    current_iteration: integer(),
    progress_percent: integer(),
    stage_start_time: DateTime.t(),
    total_start_time: DateTime.t(),
    estimated_completion: DateTime.t() | nil,
    stage_history: [map()],
    is_cancelled: boolean()
  }

  # Default configuration values
  @default_progress_interval 500  # 500ms between progress updates
  @stage_weights %{
    initializing: 5,
    evaluation: 25,
    feedback_generation: 15,
    refinement: 30,
    validation: 15,
    iteration_check: 5,
    finalizing: 5
  }

  # Historical timing data for estimation (in milliseconds)
  @average_stage_times %{
    initializing: 1000,
    evaluation: 8000,
    feedback_generation: 5000,
    refinement: 12000,
    validation: 6000,
    iteration_check: 2000,
    finalizing: 2000
  }

  ## Public API

  @doc """
  Starts progress tracking for a reflection session.

  ## Parameters
  - session_id: Unique identifier for the reflection session
  - stream_pid: Process to receive progress updates
  - options: Optional configuration for progress tracking

  ## Returns
  - {:ok, tracker_ref} on successful start
  - {:error, reason} if tracking fails to start

  ## Progress Events sent to stream_pid
  - {:reflection_progress, tracker_ref, stage, percent, description} - Progress updates
  - {:reflection_stage_complete, tracker_ref, stage, duration_ms} - Stage completion
  - {:reflection_iteration_complete, tracker_ref, iteration, total_iterations} - Iteration completion
  - {:reflection_complete, tracker_ref, total_duration_ms, result} - Final completion
  - {:reflection_cancelled, tracker_ref, reason} - Cancellation notification
  - {:reflection_error, tracker_ref, stage, reason} - Error notification
  """
  @spec start_tracking(String.t(), pid(), map()) :: {:ok, tracker_ref()} | {:error, term()}
  def start_tracking(session_id, stream_pid, options \\ %{}) do
    GenServer.call(__MODULE__, {:start_tracking, session_id, stream_pid, options})
  end

  @doc """
  Updates progress for a specific reflection stage.

  ## Parameters
  - tracker_ref: Reference to the progress tracking session
  - stage: Current reflection stage
  - progress_percent: Progress percentage (0-100)
  - description: Human-readable description of current activity

  ## Returns
  - :ok if update successful
  - {:error, reason} if update fails
  """
  @spec update_progress(tracker_ref(), reflection_stage(), integer(), String.t()) :: :ok | {:error, term()}
  def update_progress(tracker_ref, stage, progress_percent, description) do
    GenServer.call(__MODULE__, {:update_progress, tracker_ref, stage, progress_percent, description})
  end

  @doc """
  Updates progress for iteration-based tracking.

  ## Parameters
  - tracker_ref: Reference to the progress tracking session
  - current_iteration: Current iteration number
  - total_iterations: Total expected iterations
  - stage: Current stage within the iteration
  - description: Description of current activity

  ## Returns
  - :ok if update successful
  - {:error, reason} if update fails
  """
  @spec update_iteration_progress(tracker_ref(), integer(), integer(), reflection_stage(), String.t()) :: :ok | {:error, term()}
  def update_iteration_progress(tracker_ref, current_iteration, total_iterations, stage, description) do
    # Calculate overall progress based on iteration and stage
    iteration_progress = (current_iteration - 1) / total_iterations * 100
    stage_weight = Map.get(@stage_weights, stage, 10)
    stage_progress = stage_weight / 100 * 100 / total_iterations

    overall_progress = min(trunc(iteration_progress + stage_progress), 95)  # Cap at 95% until completion

    GenServer.cast(__MODULE__, {:update_iteration_progress, tracker_ref, current_iteration, total_iterations, stage, overall_progress, description})
  end

  @doc """
  Completes progress tracking with final results.

  ## Parameters
  - tracker_ref: Reference to the progress tracking session
  - result: Final reflection result

  ## Returns
  - :ok if completion successful
  - {:error, reason} if completion fails
  """
  @spec complete_tracking(tracker_ref(), term()) :: :ok | {:error, term()}
  def complete_tracking(tracker_ref, result) do
    GenServer.cast(__MODULE__, {:complete_tracking, tracker_ref, result})
  end

  @doc """
  Cancels an active progress tracking session.

  ## Parameters
  - tracker_ref: Reference to the progress tracking session to cancel
  - reason: Optional reason for cancellation

  ## Returns
  - :ok if cancellation successful
  - {:error, reason} if cancellation fails
  """
  @spec cancel_tracking(tracker_ref(), String.t()) :: :ok | {:error, term()}
  def cancel_tracking(tracker_ref, reason \\ "User requested cancellation") do
    GenServer.cast(__MODULE__, {:cancel_tracking, tracker_ref, reason})
  end

  @doc """
  Gets the current progress status for a tracking session.

  ## Parameters
  - tracker_ref: Reference to the progress tracking session

  ## Returns
  - {:ok, progress_info} if session exists
  - {:error, :not_found} if session not found
  """
  @spec get_progress_status(tracker_ref()) :: {:ok, map()} | {:error, :not_found}
  def get_progress_status(tracker_ref) do
    GenServer.call(__MODULE__, {:get_progress_status, tracker_ref})
  end

  @doc """
  Lists all active progress tracking sessions.

  ## Returns
  - List of {tracker_ref, session_id, current_stage, progress_percent} tuples
  """
  @spec list_active_sessions() :: [{tracker_ref(), String.t(), reflection_stage(), integer()}]
  def list_active_sessions() do
    GenServer.call(__MODULE__, :list_active_sessions)
  end

  @doc """
  Starts the ReflectionProgressTracker GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize state with empty tracking sessions
    state = %{
      sessions: %{},  # tracker_ref -> progress_state
      session_to_ref: %{}  # session_id -> tracker_ref
    }

    Logger.info("ReflectionProgressTracker started")
    {:ok, state}
  end

  @impl true
  def handle_call({:start_tracking, session_id, stream_pid, options}, _from, state) do
    Logger.info("Starting progress tracking for reflection session: #{session_id}")

    # Generate unique tracker reference
    tracker_ref = make_ref()

    # Create progress configuration
    progress_config = %{
      session_id: session_id,
      stream_pid: stream_pid,
      max_iterations: Map.get(options, :max_iterations, 3),
      enable_time_estimation: Map.get(options, :enable_time_estimation, true),
      progress_interval_ms: Map.get(options, :progress_interval_ms, @default_progress_interval),
      detailed_logging: Map.get(options, :detailed_logging, false)
    }

    # Initialize progress state
    now = DateTime.utc_now()
    progress_state = %{
      tracker_ref: tracker_ref,
      session_id: session_id,
      stream_pid: stream_pid,
      config: progress_config,
      current_stage: :initializing,
      current_iteration: 0,
      progress_percent: 0,
      stage_start_time: now,
      total_start_time: now,
      estimated_completion: nil,
      stage_history: [],
      is_cancelled: false
    }

    # Update state
    new_state = %{state |
      sessions: Map.put(state.sessions, tracker_ref, progress_state),
      session_to_ref: Map.put(state.session_to_ref, session_id, tracker_ref)
    }

    # Send initial progress event
    send_progress_event(stream_pid, :reflection_progress, tracker_ref, :initializing, 0, "Initializing reflection process")

    # Calculate initial time estimate if enabled
    if progress_config.enable_time_estimation do
      estimated_completion = calculate_estimated_completion(progress_config.max_iterations)
      updated_progress_state = %{progress_state | estimated_completion: estimated_completion}
      final_state = %{new_state | sessions: Map.put(new_state.sessions, tracker_ref, updated_progress_state)}
      {:reply, {:ok, tracker_ref}, final_state}
    else
      {:reply, {:ok, tracker_ref}, new_state}
    end
  end

  @impl true
  def handle_call({:get_progress_status, tracker_ref}, _from, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil -> {:reply, {:error, :not_found}, state}
      progress_state ->
        status_info = %{
          session_id: progress_state.session_id,
          current_stage: progress_state.current_stage,
          current_iteration: progress_state.current_iteration,
          progress_percent: progress_state.progress_percent,
          estimated_completion: progress_state.estimated_completion,
          is_cancelled: progress_state.is_cancelled,
          duration_ms: DateTime.diff(DateTime.utc_now(), progress_state.total_start_time, :millisecond)
        }
        {:reply, {:ok, status_info}, state}
    end
  end

  @impl true
  def handle_call(:list_active_sessions, _from, state) do
    active_sessions = state.sessions
    |> Enum.map(fn {tracker_ref, progress_state} ->
      {tracker_ref, progress_state.session_id, progress_state.current_stage, progress_state.progress_percent}
    end)

    {:reply, active_sessions, state}
  end

  @impl true
  def handle_call({:update_progress, tracker_ref, stage, progress_percent, description}, _from, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil ->
        Logger.warning("Progress update for unknown tracker: #{inspect(tracker_ref)}")
        {:reply, {:error, :not_found}, state}

      progress_state ->
        # Check if cancelled locally or via cancellation manager
        is_cancelled = progress_state.is_cancelled or check_external_cancellation(progress_state.session_id)

        if is_cancelled do
          Logger.debug("Ignoring progress update for cancelled session: #{progress_state.session_id}")
          {:reply, {:error, :cancelled}, state}
        else
          # Update progress state
          now = DateTime.utc_now()

          # Record stage completion if stage changed
          updated_history = if progress_state.current_stage != stage do
            stage_duration = DateTime.diff(now, progress_state.stage_start_time, :millisecond)
            stage_record = %{
              stage: progress_state.current_stage,
              duration_ms: stage_duration,
              completed_at: now
            }

            # Send stage completion event
            send_progress_event(progress_state.stream_pid, :reflection_stage_complete, tracker_ref, progress_state.current_stage, stage_duration, "Stage completed")

            [stage_record | progress_state.stage_history]
          else
            progress_state.stage_history
          end

          updated_progress_state = %{progress_state |
            current_stage: stage,
            progress_percent: min(progress_percent, 100),
            stage_start_time: if(progress_state.current_stage != stage, do: now, else: progress_state.stage_start_time),
            stage_history: updated_history
          }

          new_state = %{state |
            sessions: Map.put(state.sessions, tracker_ref, updated_progress_state)
          }

          # Send progress event
          send_progress_event(progress_state.stream_pid, :reflection_progress, tracker_ref, stage, progress_percent, description)

          # Log detailed progress if enabled
          if progress_state.config.detailed_logging do
            Logger.debug("Reflection progress [#{progress_state.session_id}]: #{stage} - #{progress_percent}% - #{description}")
          end

          {:reply, :ok, new_state}
        end
    end
  end

  @impl true
  def handle_cast({:update_progress, tracker_ref, stage, progress_percent, description}, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil ->
        Logger.warning("Progress update for unknown tracker: #{inspect(tracker_ref)}")
        {:noreply, state}

      progress_state ->
        if progress_state.is_cancelled do
          Logger.debug("Ignoring progress update for cancelled session: #{progress_state.session_id}")
          {:noreply, state}
        else
          # Update progress state
          now = DateTime.utc_now()

          # Record stage completion if stage changed
          updated_history = if progress_state.current_stage != stage do
            stage_duration = DateTime.diff(now, progress_state.stage_start_time, :millisecond)
            stage_record = %{
              stage: progress_state.current_stage,
              duration_ms: stage_duration,
              completed_at: now
            }

            # Send stage completion event
            send_progress_event(progress_state.stream_pid, :reflection_stage_complete, tracker_ref, progress_state.current_stage, stage_duration, "Stage completed")

            [stage_record | progress_state.stage_history]
          else
            progress_state.stage_history
          end

          updated_progress_state = %{progress_state |
            current_stage: stage,
            progress_percent: min(progress_percent, 100),
            stage_start_time: if(progress_state.current_stage != stage, do: now, else: progress_state.stage_start_time),
            stage_history: updated_history
          }

          new_state = %{state |
            sessions: Map.put(state.sessions, tracker_ref, updated_progress_state)
          }

          # Send progress event
          send_progress_event(progress_state.stream_pid, :reflection_progress, tracker_ref, stage, progress_percent, description)

          # Log detailed progress if enabled
          if progress_state.config.detailed_logging do
            Logger.debug("Reflection progress [#{progress_state.session_id}]: #{stage} - #{progress_percent}% - #{description}")
          end

          {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_cast({:update_iteration_progress, tracker_ref, current_iteration, total_iterations, stage, overall_progress, description}, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil ->
        Logger.warning("Iteration progress update for unknown tracker: #{inspect(tracker_ref)}")
        {:noreply, state}

      progress_state ->
        if progress_state.is_cancelled do
          Logger.debug("Ignoring iteration progress update for cancelled session: #{progress_state.session_id}")
          {:noreply, state}
        else
          # Check if iteration changed
          iteration_changed = progress_state.current_iteration != current_iteration

          # Update progress state
          updated_progress_state = %{progress_state |
            current_iteration: current_iteration,
            current_stage: stage,
            progress_percent: overall_progress
          }

          new_state = %{state |
            sessions: Map.put(state.sessions, tracker_ref, updated_progress_state)
          }

          # Send iteration completion event if iteration changed
          if iteration_changed and current_iteration > 0 do
            send_progress_event(progress_state.stream_pid, :reflection_iteration_complete, tracker_ref, current_iteration, total_iterations, "Iteration #{current_iteration} completed")
          end

          # Send regular progress event
          iteration_description = "Iteration #{current_iteration}/#{total_iterations}: #{description}"
          send_progress_event(progress_state.stream_pid, :reflection_progress, tracker_ref, stage, overall_progress, iteration_description)

          {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_cast({:complete_tracking, tracker_ref, result}, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil ->
        Logger.warning("Completion for unknown tracker: #{inspect(tracker_ref)}")
        {:noreply, state}

      progress_state ->
        Logger.info("Completing progress tracking for session: #{progress_state.session_id}")

        # Calculate total duration
        total_duration = DateTime.diff(DateTime.utc_now(), progress_state.total_start_time, :millisecond)

        # Send completion event
        send_progress_event(progress_state.stream_pid, :reflection_complete, tracker_ref, :completed, 100, "Reflection process completed successfully")
        send_progress_event(progress_state.stream_pid, :reflection_complete, tracker_ref, total_duration, result, "Final result available")

        # Clean up state
        new_state = %{state |
          sessions: Map.delete(state.sessions, tracker_ref),
          session_to_ref: Map.delete(state.session_to_ref, progress_state.session_id)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:cancel_tracking, tracker_ref, reason}, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil ->
        Logger.warning("Cancellation for unknown tracker: #{inspect(tracker_ref)}")
        {:noreply, state}

      progress_state ->
        Logger.info("Cancelling progress tracking for session: #{progress_state.session_id}, reason: #{reason}")

        # Update state to mark as cancelled
        updated_progress_state = %{progress_state | is_cancelled: true}

        updated_state = %{state |
          sessions: Map.put(state.sessions, tracker_ref, updated_progress_state)
        }

        # Send cancellation event
        send_progress_event(progress_state.stream_pid, :reflection_cancelled, tracker_ref, :cancelled, 0, reason)

        # Schedule cleanup after a delay to allow final processing
        Process.send_after(self(), {:cleanup_session, tracker_ref}, 1000)

        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_info({:cleanup_session, tracker_ref}, state) do
    case Map.get(state.sessions, tracker_ref) do
      nil ->
        {:noreply, state}

      progress_state ->
        Logger.debug("Cleaning up progress tracking session: #{progress_state.session_id}")

        new_state = %{state |
          sessions: Map.delete(state.sessions, tracker_ref),
          session_to_ref: Map.delete(state.session_to_ref, progress_state.session_id)
        }

        {:noreply, new_state}
    end
  end

  ## Private Functions

  defp send_progress_event(stream_pid, event_type, tracker_ref, stage_or_data, progress_or_extra, description) do
    event = {event_type, tracker_ref, stage_or_data, progress_or_extra, description}
    send(stream_pid, event)
  end

  defp calculate_estimated_completion(max_iterations) do
    # Calculate estimated total time based on average stage times and iterations
    single_iteration_time = @average_stage_times
    |> Map.values()
    |> Enum.sum()

    total_estimated_time = single_iteration_time * max_iterations + Map.get(@average_stage_times, :initializing, 1000) + Map.get(@average_stage_times, :finalizing, 2000)

    DateTime.add(DateTime.utc_now(), total_estimated_time, :millisecond)
  end

  defp check_external_cancellation(session_id) do
    # Check if the session is cancelled via the cancellation manager
    try do
      case DecisionEngine.ReflectionCancellationManager.list_active_processes() do
        processes when is_list(processes) ->
          Enum.any?(processes, fn {_ref, sid, status} ->
            sid == session_id and status in [:cancelling, :cancelled]
          end)
        _ -> false
      end
    rescue
      _ -> false
    end
  end
end
