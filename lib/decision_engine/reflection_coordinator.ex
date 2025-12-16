defmodule DecisionEngine.ReflectionCoordinator do
  @moduledoc """
  Orchestrates the multi-pass reflection process and manages iteration control.

  The ReflectionCoordinator is the central component that manages the agentic reflection
  pipeline, coordinating between the ReflectionAgent, RefinementAgent, and QualityValidator
  to iteratively improve domain configurations through self-reflection.
  """

  require Logger
  alias DecisionEngine.ReflectionAgent
  alias DecisionEngine.RefinementAgent
  alias DecisionEngine.QualityValidator
  alias DecisionEngine.ReflectionConfig
  alias DecisionEngine.ReflectionResult
  alias DecisionEngine.ReflectionProgressTracker
  alias DecisionEngine.ReflectionCancellationManager
  alias DecisionEngine.ReflectionQueueManager
  alias DecisionEngine.Types

  @type reflection_options :: %{
    max_iterations: integer(),
    quality_threshold: float(),
    timeout_ms: integer(),
    enable_progress_tracking: boolean(),
    enable_cancellation: boolean(),
    stream_pid: pid() | nil,
    custom_prompts: map()
  }

  @type termination_reason :: :quality_threshold_met | :max_iterations_reached | :timeout_exceeded | :no_improvement | :error

  @doc """
  Starts the reflection pipeline for a given domain configuration.

  Initiates the multi-pass reflection process with configurable options for iteration
  control, quality thresholds, timeout handling, progress tracking, and cancellation support.

  ## Parameters
  - domain_config: The initial domain configuration map to improve
  - options: Optional reflection configuration (uses system defaults if not provided)

  ## Returns
  - {:ok, reflection_result} on successful completion
  - {:error, reason} if reflection fails
  - {:cancelled, reason} if reflection was cancelled
  """
  @spec start_reflection(map(), reflection_options() | nil) :: {:ok, ReflectionResult.t()} | {:error, String.t()} | {:cancelled, String.t()}

  @doc """
  Queues a reflection request for concurrent processing.

  This method provides non-blocking reflection processing by queuing the request
  and processing it when resources become available. Multiple reflection requests
  can be processed concurrently without blocking other system operations.

  ## Parameters
  - domain_config: The initial domain configuration map to improve
  - options: Reflection options including priority and callback configuration

  ## Returns
  - {:ok, request_id} if request queued successfully
  - {:error, reason} if queueing fails

  ## Options
  - priority: :low | :normal | :high | :urgent (default: :normal)
  - callback_pid: Process to receive completion notifications
  - session_id: Optional session identifier for tracking
  - async: Set to true to enable non-blocking processing (default: false)
  """
  @spec start_reflection_async(map(), reflection_options() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def start_reflection_async(domain_config, options \\ nil) when is_map(domain_config) do
    with :ok <- Types.validate_rule_config(domain_config),
         {:ok, reflection_options} <- prepare_reflection_options(options) do

      # Add async flag and callback configuration
      queue_options = reflection_options
      |> Map.put(:async, true)
      |> Map.put(:callback_pid, Map.get(reflection_options, :callback_pid, self()))

      # Queue the reflection request
      case ReflectionQueueManager.queue_reflection(domain_config, queue_options) do
        {:ok, request_id} ->
          Logger.info("Queued reflection request #{request_id} for domain: #{domain_config["domain"]}")
          {:ok, request_id}

        {:error, reason} ->
          Logger.error("Failed to queue reflection request: #{reason}")
          {:error, "Failed to queue reflection: #{reason}"}
      end
    else
      {:error, reason} -> {:error, "Reflection initialization failed: #{reason}"}
    end
  end

  @doc """
  Gets the status of a queued or processing reflection request.

  ## Parameters
  - request_id: The request identifier returned by start_reflection_async

  ## Returns
  - {:ok, request_info} if request found
  - {:error, :not_found} if request not found
  """
  @spec get_reflection_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_reflection_status(request_id) do
    ReflectionQueueManager.get_request_status(request_id)
  end

  @doc """
  Cancels a queued or processing reflection request.

  ## Parameters
  - request_id: The request identifier to cancel

  ## Returns
  - :ok if cancellation initiated
  - {:error, reason} if cancellation fails
  """
  @spec cancel_reflection_request(String.t()) :: :ok | {:error, term()}
  def cancel_reflection_request(request_id) do
    ReflectionQueueManager.cancel_request(request_id)
  end

  @doc """
  Lists all active reflection requests.

  ## Returns
  - List of active reflection request information
  """
  @spec list_active_reflections() :: [map()]
  def list_active_reflections() do
    ReflectionQueueManager.list_active_requests()
  end

  @doc """
  Gets current reflection queue status and metrics.

  ## Returns
  - Map containing queue statistics and performance metrics
  """
  @spec get_queue_metrics() :: map()
  def get_queue_metrics() do
    ReflectionQueueManager.get_queue_status()
  end
  def start_reflection(domain_config, options \\ nil) when is_map(domain_config) do
    with :ok <- Types.validate_rule_config(domain_config),
         {:ok, reflection_options} <- prepare_reflection_options(options),
         {:ok, initial_quality} <- ReflectionAgent.calculate_quality_scores(domain_config) do

      Logger.info("Starting reflection process for domain: #{domain_config["domain"]}")

      start_time = System.monotonic_time(:millisecond)
      session_id = generate_session_id(domain_config)

      # Initialize progress tracking if enabled
      {tracker_ref, cancellation_ref} = initialize_tracking_and_cancellation(session_id, reflection_options)

      reflection_state = %{
        original_config: domain_config,
        current_config: domain_config,
        current_quality: initial_quality,
        iteration_count: 0,
        improvement_history: [],
        start_time: start_time,
        session_id: session_id,
        tracker_ref: tracker_ref,
        cancellation_ref: cancellation_ref,
        options: reflection_options
      }

      case execute_reflection_pipeline(reflection_state) do
        {:ok, final_state} ->
          result = build_reflection_result(final_state)
          Logger.info("Reflection completed successfully after #{final_state.iteration_count} iterations")

          # Complete progress tracking
          if tracker_ref, do: ReflectionProgressTracker.complete_tracking(tracker_ref, result)

          # Trigger resource cleanup
          cleanup_reflection_resources(final_state)

          {:ok, result}

        {:cancelled, reason} ->
          Logger.info("Reflection cancelled: #{reason}")

          # Complete progress tracking with cancellation
          if tracker_ref, do: ReflectionProgressTracker.cancel_tracking(tracker_ref, reason)

          # Trigger resource cleanup for cancelled process
          cleanup_reflection_resources(reflection_state)

          {:cancelled, reason}

        {:error, reason} ->
          Logger.error("Reflection failed: #{reason}")

          # Complete progress tracking with error
          if tracker_ref, do: ReflectionProgressTracker.cancel_tracking(tracker_ref, "Error: #{reason}")

          # Trigger resource cleanup for failed process
          cleanup_reflection_resources(reflection_state)

          {:error, reason}
      end
    else
      {:error, reason} -> {:error, "Reflection initialization failed: #{reason}"}
    end
  end

  @doc """
  Coordinates a single reflection iteration.

  Manages one cycle of the reflection process: evaluation, feedback generation,
  refinement application, and quality validation.

  ## Parameters
  - config: Current domain configuration
  - feedback: Reflection feedback from previous evaluation
  - iteration_count: Current iteration number

  ## Returns
  - {:ok, {refined_config, quality_score, improvement_metrics}} on success
  - {:error, reason} if iteration fails
  """
  @spec coordinate_iteration(map(), DecisionEngine.ReflectionFeedback.t(), integer()) ::
    {:ok, {map(), DecisionEngine.QualityScore.t(), map()}} | {:error, String.t()}
  def coordinate_iteration(config, feedback, iteration_count) when is_map(config) do
    Logger.debug("Executing reflection iteration #{iteration_count}")

    with {:ok, refined_config} <- RefinementAgent.apply_improvements(config, feedback),
         {:ok, refined_quality} <- ReflectionAgent.calculate_quality_scores(refined_config),
         {:ok, validation_result} <- QualityValidator.validate_improvements(config, refined_config) do

      improvement_metrics = %{
        is_improvement: validation_result.is_improvement,
        quality_change: validation_result.quality_change,
        improved_dimensions: validation_result.improved_dimensions,
        degraded_dimensions: validation_result.degraded_dimensions,
        iteration: iteration_count
      }

      if validation_result.recommendation == :accept do
        {:ok, {refined_config, refined_quality, improvement_metrics}}
      else
        Logger.warning("Iteration #{iteration_count} refinement not accepted: #{validation_result.recommendation}")
        {:error, "Refinement validation failed: #{validation_result.recommendation}"}
      end
    else
      {:error, reason} -> {:error, "Iteration #{iteration_count} failed: #{reason}"}
    end
  end

  @doc """
  Evaluates termination criteria for the reflection process.

  Determines whether the reflection process should continue based on quality scores,
  iteration count, timeout, and improvement trends.

  ## Parameters
  - quality_scores: List of quality scores from iterations
  - iteration_count: Current iteration number
  - options: Reflection options with thresholds and limits

  ## Returns
  - {:continue, reason} if reflection should continue
  - {:terminate, reason} if reflection should stop
  """
  @spec evaluate_termination_criteria([DecisionEngine.QualityScore.t()], integer(), reflection_options()) ::
    {:continue, String.t()} | {:terminate, termination_reason()}
  def evaluate_termination_criteria(quality_scores, iteration_count, options) do
    current_quality = List.last(quality_scores)

    cond do
      # Check if quality threshold is met
      current_quality.overall >= options.quality_threshold ->
        {:terminate, :quality_threshold_met}

      # Check if maximum iterations reached
      iteration_count >= options.max_iterations ->
        {:terminate, :max_iterations_reached}

      # Check for lack of improvement over recent iterations
      no_recent_improvement?(quality_scores, 2) ->
        {:terminate, :no_improvement}

      # Continue if none of the termination criteria are met
      true ->
        {:continue, "Quality: #{Float.round(current_quality.overall, 3)}, Iteration: #{iteration_count}/#{options.max_iterations}"}
    end
  end

  @doc """
  Handles timeout and resource constraints during reflection.

  Monitors processing time and resource usage, implementing graceful degradation
  when constraints are exceeded.

  ## Parameters
  - start_time: Process start time in milliseconds
  - options: Reflection options with timeout settings
  - current_iteration: Current iteration number

  ## Returns
  - :ok if within constraints
  - {:timeout, elapsed_time} if timeout exceeded
  - {:resource_limit, details} if resource limits exceeded
  """
  @spec handle_timeout_and_resources(integer(), reflection_options(), integer()) ::
    :ok | {:timeout, integer()} | {:resource_limit, String.t()}
  def handle_timeout_and_resources(start_time, options, current_iteration) do
    current_time = System.monotonic_time(:millisecond)
    elapsed_time = current_time - start_time

    cond do
      # Check timeout
      elapsed_time > options.timeout_ms ->
        {:timeout, elapsed_time}

      # Check if we're approaching timeout and should reduce iterations
      elapsed_time > (options.timeout_ms * 0.8) and current_iteration < options.max_iterations ->
        Logger.warning("Approaching timeout, may need to reduce remaining iterations")
        :ok

      # Check memory usage (simplified check)
      excessive_memory_usage?() ->
        {:resource_limit, "Memory usage exceeded safe limits"}

      true ->
        :ok
    end
  end

  # Private functions for reflection pipeline execution

  defp execute_reflection_pipeline(state) do
    # Check for cancellation first
    if is_cancelled?(state.cancellation_ref) do
      {:cancelled, "Reflection process was cancelled"}
    else
      case handle_timeout_and_resources(state.start_time, state.options, state.iteration_count) do
        :ok ->
          execute_reflection_iteration(state)

        {:timeout, elapsed_time} ->
          Logger.warning("Reflection timeout after #{elapsed_time}ms")
          {:ok, Map.put(state, :termination_reason, :timeout_exceeded)}

        {:resource_limit, details} ->
          Logger.warning("Resource limit exceeded: #{details}")
          {:ok, Map.put(state, :termination_reason, :resource_limit)}
      end
    end
  end

  defp execute_reflection_iteration(state) do
    # Check for cancellation before starting iteration
    if is_cancelled?(state.cancellation_ref) do
      {:cancelled, "Reflection process was cancelled during iteration"}
    else
      # Update progress for evaluation stage
      update_progress(state, :evaluation, calculate_progress_percent(state), "Evaluating domain configuration quality")

      # Register current process as a resource for cleanup if we have cancellation support
      if state.cancellation_ref do
        ReflectionCancellationManager.register_resource(state.cancellation_ref, :process, self())
      end

      # Evaluate current configuration and generate feedback
      case ReflectionAgent.generate_feedback(state.current_config) do
        {:ok, feedback} ->
          # Check for cancellation after evaluation
          if is_cancelled?(state.cancellation_ref) do
            {:cancelled, "Reflection process was cancelled after evaluation"}
          else
            # Check if we have actionable feedback
            if DecisionEngine.ReflectionFeedback.has_actionable_suggestions?(feedback) do
              execute_improvement_iteration(state, feedback)
            else
              # No actionable feedback, terminate with current state
              Logger.info("No actionable feedback generated, terminating reflection")
              {:ok, Map.put(state, :termination_reason, :no_improvement)}
            end
          end

        {:error, reason} ->
          {:error, "Failed to generate feedback: #{reason}"}
      end
    end
  end

  defp execute_improvement_iteration(state, feedback) do
    iteration_count = state.iteration_count + 1

    # Update progress for feedback generation
    update_progress(state, :feedback_generation, calculate_progress_percent(state, iteration_count), "Generating improvement feedback")

    # Check for cancellation before refinement
    if is_cancelled?(state.cancellation_ref) do
      {:cancelled, "Reflection process was cancelled before refinement"}
    else
      # Update progress for refinement
      update_progress(state, :refinement, calculate_progress_percent(state, iteration_count), "Applying improvements to domain configuration")

      case coordinate_iteration(state.current_config, feedback, iteration_count) do
        {:ok, {refined_config, refined_quality, improvement_metrics}} ->
          # Check for cancellation after refinement
          if is_cancelled?(state.cancellation_ref) do
            {:cancelled, "Reflection process was cancelled after refinement"}
          else
            # Update progress for validation
            update_progress(state, :validation, calculate_progress_percent(state, iteration_count), "Validating improvements")

            # Update state with new results
            updated_state = %{state |
              current_config: refined_config,
              current_quality: refined_quality,
              iteration_count: iteration_count,
              improvement_history: [improvement_metrics | state.improvement_history]
            }

            # Update iteration progress
            update_iteration_progress(updated_state, iteration_count, state.options.max_iterations, :iteration_check, "Checking termination criteria")

            # Check termination criteria
            quality_history = [refined_quality | extract_quality_history(state.improvement_history)]

            case evaluate_termination_criteria(quality_history, iteration_count, state.options) do
              {:continue, reason} ->
                Logger.debug("Continuing reflection: #{reason}")
                execute_reflection_pipeline(updated_state)

              {:terminate, termination_reason} ->
                Logger.info("Reflection terminated: #{termination_reason}")
                {:ok, Map.put(updated_state, :termination_reason, termination_reason)}
            end
          end

        {:error, reason} ->
          Logger.warning("Iteration #{iteration_count} failed: #{reason}")

          # If this is the first iteration and we have a low quality threshold,
          # still return success with original config
          if iteration_count == 1 and state.options.quality_threshold <= 0.2 do
            Logger.info("First iteration failed but quality threshold is low, returning original config")
            {:ok, Map.put(state, :termination_reason, :no_improvement)}
          else
            # If this is the first iteration with higher threshold, it's a failure
            if iteration_count == 1 do
              {:error, reason}
            else
              # Otherwise, terminate with current best state
              {:ok, Map.put(state, :termination_reason, :error)}
            end
          end
      end
    end
  end

  defp prepare_reflection_options(nil) do
    # Use system configuration defaults
    case ReflectionConfig.get_current_config() do
      {:ok, config} ->
        options = %{
          max_iterations: config.max_iterations,
          quality_threshold: config.quality_threshold,
          timeout_ms: config.timeout_ms,
          enable_progress_tracking: true,
          custom_prompts: config.custom_prompts
        }
        {:ok, options}

      {:error, _reason} ->
        # Fallback to hardcoded defaults
        default_options = %{
          max_iterations: 3,
          quality_threshold: 0.75,
          timeout_ms: 300_000,  # 5 minutes
          enable_progress_tracking: true,
          enable_cancellation: true,
          stream_pid: nil,
          custom_prompts: %{}
        }
        {:ok, default_options}
    end
  end

  defp prepare_reflection_options(options) when is_map(options) do
    # Validate and merge with defaults
    {:ok, default_options} = prepare_reflection_options(nil)
    merged_options = Map.merge(default_options, options)

    # Validate option values
    with :ok <- validate_max_iterations(merged_options.max_iterations),
         :ok <- validate_quality_threshold(merged_options.quality_threshold),
         :ok <- validate_timeout(merged_options.timeout_ms) do
      {:ok, merged_options}
    else
      {:error, reason} -> {:error, "Invalid reflection options: #{reason}"}
    end
  end

  defp validate_max_iterations(iterations) when is_integer(iterations) and iterations >= 1 and iterations <= 5, do: :ok
  defp validate_max_iterations(iterations), do: {:error, "max_iterations must be between 1 and 5, got #{iterations}"}

  defp validate_quality_threshold(threshold) when is_number(threshold) and threshold >= 0.0 and threshold <= 1.0, do: :ok
  defp validate_quality_threshold(threshold), do: {:error, "quality_threshold must be between 0.0 and 1.0, got #{threshold}"}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(timeout), do: {:error, "timeout_ms must be a positive integer, got #{timeout}"}

  defp no_recent_improvement?(quality_scores, lookback_count) when length(quality_scores) < lookback_count + 1 do
    false  # Not enough data to determine trend
  end

  defp no_recent_improvement?(quality_scores, lookback_count) do
    recent_scores = Enum.take(quality_scores, lookback_count + 1)
    [current | previous_scores] = recent_scores

    # Check if current score is not significantly better than recent scores
    Enum.all?(previous_scores, fn prev_score ->
      current.overall - prev_score.overall < 0.01  # Less than 1% improvement
    end)
  end

  defp extract_quality_history(_improvement_history) do
    # This would need to be implemented based on how quality scores are stored in improvement_history
    # For now, return empty list as placeholder
    []
  end

  defp excessive_memory_usage?() do
    # Simplified memory check - in production, this would use proper memory monitoring
    case :erlang.memory(:total) do
      total when total > 1_000_000_000 -> true  # 1GB threshold
      _ -> false
    end
  end

  defp build_reflection_result(final_state) do
    end_time = System.monotonic_time(:millisecond)
    total_processing_time = end_time - final_state.start_time

    # Calculate improvement metrics
    original_quality = case ReflectionAgent.calculate_quality_scores(final_state.original_config) do
      {:ok, quality} -> quality
      {:error, _} -> %DecisionEngine.QualityScore{overall: 0.0, completeness: 0.0, accuracy: 0.0, consistency: 0.0, usability: 0.0, detailed_feedback: []}
    end

    quality_improvement = final_state.current_quality.overall - original_quality.overall

    # Extract improvement areas from history
    improvement_areas = final_state.improvement_history
    |> Enum.flat_map(& &1.improved_dimensions)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_dim, count} -> count end, :desc)
    |> Enum.map(fn {dim, _count} -> dim end)

    # Extract applied feedback from history
    feedback_applied = final_state.improvement_history
    |> Enum.with_index()
    |> Enum.map(fn {metrics, index} ->
      "Iteration #{index + 1}: #{length(metrics.improved_dimensions)} dimensions improved"
    end)

    result = ReflectionResult.new(
      final_state.original_config,
      final_state.current_config,
      %{
        original: original_quality,
        refined: final_state.current_quality,
        improvement: quality_improvement
      },
      %{
        iterations_performed: final_state.iteration_count,
        total_processing_time: total_processing_time,
        improvement_areas: improvement_areas,
        feedback_applied: feedback_applied,
        termination_reason: Map.get(final_state, :termination_reason, :completed),
        session_id: final_state.session_id
      }
    )

    # Register the result as a large memory resource for cleanup tracking
    if final_state.cancellation_ref do
      ReflectionCancellationManager.register_resource(final_state.cancellation_ref, :memory, {:large_binary, :reflection_result})
    end

    # Trigger garbage collection to clean up intermediate data
    :erlang.garbage_collect()

    result
  end

  # Progress tracking and cancellation helper functions

  defp generate_session_id(domain_config) do
    domain_name = Map.get(domain_config, "name", Map.get(domain_config, :name, "unknown"))
    timestamp = System.system_time(:millisecond)
    "reflection_#{domain_name}_#{timestamp}"
  end

  defp initialize_tracking_and_cancellation(session_id, options) do
    tracker_ref = if options.enable_progress_tracking and options.stream_pid do
      case ReflectionProgressTracker.start_tracking(session_id, options.stream_pid, options) do
        {:ok, ref} -> ref
        {:error, reason} ->
          Logger.warning("Failed to start progress tracking: #{inspect(reason)}")
          nil
      end
    else
      nil
    end

    cancellation_ref = if options.enable_cancellation do
      case ReflectionCancellationManager.register_process(session_id, self(), options) do
        {:ok, ref} ->
          # Register the tracker as a resource for cleanup
          if tracker_ref do
            ReflectionCancellationManager.register_resource(ref, :process, tracker_ref)
          end
          ref
        {:error, reason} ->
          Logger.warning("Failed to register for cancellation: #{inspect(reason)}")
          nil
      end
    else
      nil
    end

    {tracker_ref, cancellation_ref}
  end

  defp is_cancelled?(nil), do: false
  defp is_cancelled?(cancellation_ref) do
    case ReflectionCancellationManager.is_cancelled?(cancellation_ref) do
      true -> true
      false -> false
      {:error, :not_found} -> false
    end
  end

  defp update_progress(state, stage, progress_percent, description) do
    if state.tracker_ref do
      ReflectionProgressTracker.update_progress(state.tracker_ref, stage, progress_percent, description)
    end
  end

  defp update_iteration_progress(state, current_iteration, total_iterations, stage, description) do
    if state.tracker_ref do
      ReflectionProgressTracker.update_iteration_progress(state.tracker_ref, current_iteration, total_iterations, stage, description)
    end
  end

  defp calculate_progress_percent(state, iteration \\ nil) do
    iteration = iteration || state.iteration_count
    max_iterations = state.options.max_iterations

    # Base progress on iteration and stage
    iteration_progress = if max_iterations > 0 do
      (iteration / max_iterations) * 80  # 80% for iterations, 20% for initialization and finalization
    else
      0
    end

    base_progress = 10 + iteration_progress  # Start at 10% after initialization
    min(trunc(base_progress), 90)  # Cap at 90% until completion
  end

  # Cleanup reflection resources and trigger final cleanup
  defp cleanup_reflection_resources(state) do
    if state.cancellation_ref do
      Logger.debug("Triggering resource cleanup for reflection session: #{state.session_id}")

      # Trigger manual cleanup of registered resources
      ReflectionCancellationManager.cleanup_resources(state.cancellation_ref)

      # Force garbage collection to clean up any remaining memory
      :erlang.garbage_collect()

      # Log memory usage after cleanup
      memory_usage = :erlang.memory(:total)
      Logger.debug("Memory usage after reflection cleanup: #{memory_usage} bytes")
    end
  end

  # Cancellation message handler
  def handle_info({:cancel_reflection, reason}, state) do
    Logger.info("Received cancellation request: #{reason}")
    # This would be handled by the GenServer if ReflectionCoordinator was a GenServer
    # For now, we'll rely on the cancellation manager to track cancellation state
    {:noreply, state}
  end
end
