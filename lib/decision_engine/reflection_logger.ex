# lib/decision_engine/reflection_logger.ex
defmodule DecisionEngine.ReflectionLogger do
  @moduledoc """
  Provides structured logging for reflection system processes and stages.

  This module implements specialized logging for the agentic reflection pattern,
  providing detailed process tracking, stage logging, and diagnostic information.
  """

  require Logger

  @log_levels [:debug, :info, :warning, :error]
  @reflection_stages [
    :initialization,
    :configuration_evaluation,
    :quality_scoring,
    :feedback_generation,
    :refinement_application,
    :validation,
    :iteration_control,
    :completion
  ]

  @doc """
  Logs the start of a reflection process with initial context.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - domain_name: Name of the domain being processed
  - config: Reflection configuration being used
  - metadata: Additional process metadata

  ## Returns
  - :ok always
  """
  @spec log_process_start(String.t(), String.t(), map(), map()) :: :ok
  def log_process_start(process_id, domain_name, config, metadata \\ %{}) do
    log_structured(:info, :initialization, %{
      event: "reflection_process_started",
      process_id: process_id,
      domain_name: domain_name,
      max_iterations: Map.get(config, :max_iterations, 0),
      quality_threshold: Map.get(config, :quality_threshold, 0.0),
      timeout_ms: Map.get(config, :timeout_ms, 0),
      metadata: metadata
    })
  end

  @doc """
  Logs the completion of a reflection process.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - success: Whether the process completed successfully
  - final_metrics: Final process metrics
  - error_reason: Optional error reason if process failed

  ## Returns
  - :ok always
  """
  @spec log_process_completion(String.t(), boolean(), map(), String.t() | nil) :: :ok
  def log_process_completion(process_id, success, final_metrics, error_reason \\ nil) do
    level = if success, do: :info, else: :error

    log_data = %{
      event: "reflection_process_completed",
      process_id: process_id,
      success: success,
      total_iterations: Map.get(final_metrics, :iterations_performed, 0),
      processing_time_ms: Map.get(final_metrics, :processing_time_ms, 0),
      quality_improvement: Map.get(final_metrics, :improvement_percentage, 0.0),
      final_quality_score: Map.get(final_metrics, :final_quality, 0.0)
    }

    log_data = if error_reason, do: Map.put(log_data, :error_reason, error_reason), else: log_data

    log_structured(level, :completion, log_data)
  end

  @doc """
  Logs the start of a reflection iteration.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - iteration: Iteration number (0 for initial, 1+ for reflections)
  - stage: Current reflection stage

  ## Returns
  - :ok always
  """
  @spec log_iteration_start(String.t(), integer(), atom()) :: :ok
  def log_iteration_start(process_id, iteration, stage) do
    log_structured(:info, stage, %{
      event: "reflection_iteration_started",
      process_id: process_id,
      iteration: iteration,
      stage: stage
    })
  end

  @doc """
  Logs quality evaluation results for an iteration.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - iteration: Iteration number
  - quality_scores: Map of quality metric scores
  - feedback_count: Number of feedback items generated

  ## Returns
  - :ok always
  """
  @spec log_quality_evaluation(String.t(), integer(), map(), integer()) :: :ok
  def log_quality_evaluation(process_id, iteration, quality_scores, feedback_count) do
    log_structured(:info, :quality_scoring, %{
      event: "quality_evaluation_completed",
      process_id: process_id,
      iteration: iteration,
      overall_score: Map.get(quality_scores, :overall, 0.0),
      completeness: Map.get(quality_scores, :completeness, 0.0),
      accuracy: Map.get(quality_scores, :accuracy, 0.0),
      consistency: Map.get(quality_scores, :consistency, 0.0),
      usability: Map.get(quality_scores, :usability, 0.0),
      feedback_items: feedback_count
    })
  end

  @doc """
  Logs feedback generation results.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - iteration: Iteration number
  - feedback: List of feedback items generated
  - priority_areas: List of priority improvement areas

  ## Returns
  - :ok always
  """
  @spec log_feedback_generation(String.t(), integer(), list(), list()) :: :ok
  def log_feedback_generation(process_id, iteration, feedback, priority_areas) do
    log_structured(:info, :feedback_generation, %{
      event: "feedback_generated",
      process_id: process_id,
      iteration: iteration,
      feedback_count: length(feedback),
      priority_areas: priority_areas,
      feedback_summary: summarize_feedback(feedback)
    })
  end

  @doc """
  Logs refinement application results.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - iteration: Iteration number
  - improvements_applied: List of improvements that were applied
  - validation_result: Result of improvement validation

  ## Returns
  - :ok always
  """
  @spec log_refinement_application(String.t(), integer(), list(), map()) :: :ok
  def log_refinement_application(process_id, iteration, improvements_applied, validation_result) do
    log_structured(:info, :refinement_application, %{
      event: "refinement_applied",
      process_id: process_id,
      iteration: iteration,
      improvements_count: length(improvements_applied),
      improvements_applied: improvements_applied,
      validation_passed: Map.get(validation_result, :valid, false),
      quality_delta: Map.get(validation_result, :quality_delta, 0.0)
    })
  end

  @doc """
  Logs iteration control decisions.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - iteration: Current iteration number
  - decision: Control decision (:continue, :terminate_quality, :terminate_iterations, :terminate_timeout)
  - reason: Reason for the decision
  - metrics: Current process metrics

  ## Returns
  - :ok always
  """
  @spec log_iteration_control(String.t(), integer(), atom(), String.t(), map()) :: :ok
  def log_iteration_control(process_id, iteration, decision, reason, metrics) do
    level = case decision do
      :continue -> :debug
      _ -> :info
    end

    log_structured(level, :iteration_control, %{
      event: "iteration_control_decision",
      process_id: process_id,
      iteration: iteration,
      decision: decision,
      reason: reason,
      current_quality: Map.get(metrics, :current_quality, 0.0),
      quality_threshold: Map.get(metrics, :quality_threshold, 0.0),
      max_iterations: Map.get(metrics, :max_iterations, 0),
      elapsed_time_ms: Map.get(metrics, :elapsed_time_ms, 0)
    })
  end

  @doc """
  Logs LLM interaction details for reflection operations.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - operation: Type of LLM operation (:evaluation, :refinement)
  - request_data: Request data sent to LLM
  - response_data: Response data received from LLM
  - timing_ms: Time taken for the operation

  ## Returns
  - :ok always
  """
  @spec log_llm_interaction(String.t(), atom(), map(), map(), integer()) :: :ok
  def log_llm_interaction(process_id, operation, request_data, response_data, timing_ms) do
    log_structured(:debug, :configuration_evaluation, %{
      event: "llm_interaction",
      process_id: process_id,
      operation: operation,
      request_size: calculate_data_size(request_data),
      response_size: calculate_data_size(response_data),
      timing_ms: timing_ms,
      model: Map.get(request_data, :model, "unknown"),
      success: Map.has_key?(response_data, :content)
    })
  end

  @doc """
  Logs error conditions during reflection processing.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - stage: Reflection stage where error occurred
  - error: Error details
  - context: Additional error context

  ## Returns
  - :ok always
  """
  @spec log_reflection_error(String.t(), atom(), term(), map()) :: :ok
  def log_reflection_error(process_id, stage, error, context \\ %{}) do
    log_structured(:error, stage, %{
      event: "reflection_error",
      process_id: process_id,
      stage: stage,
      error_type: classify_error(error),
      error_message: format_error_message(error),
      context: context,
      stacktrace: format_stacktrace(error)
    })
  end

  @doc """
  Logs performance warnings during reflection processing.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - warning_type: Type of performance warning
  - metrics: Performance metrics that triggered the warning
  - threshold: Threshold that was exceeded

  ## Returns
  - :ok always
  """
  @spec log_performance_warning(String.t(), atom(), map(), term()) :: :ok
  def log_performance_warning(process_id, warning_type, metrics, threshold) do
    log_structured(:warning, :validation, %{
      event: "performance_warning",
      process_id: process_id,
      warning_type: warning_type,
      current_value: Map.get(metrics, warning_type, 0),
      threshold: threshold,
      metrics: metrics
    })
  end

  @doc """
  Logs diagnostic information for troubleshooting.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - diagnostic_type: Type of diagnostic information
  - data: Diagnostic data

  ## Returns
  - :ok always
  """
  @spec log_diagnostic(String.t(), atom(), map()) :: :ok
  def log_diagnostic(process_id, diagnostic_type, data) do
    log_structured(:debug, :validation, %{
      event: "reflection_diagnostic",
      process_id: process_id,
      diagnostic_type: diagnostic_type,
      data: data
    })
  end

  # Private Functions

  defp log_structured(level, stage, data) when level in @log_levels and stage in @reflection_stages do
    # Add common metadata
    enriched_data = data
    |> Map.put(:timestamp, DateTime.utc_now())
    |> Map.put(:stage, stage)
    |> Map.put(:component, "reflection_system")

    # Format message for human readability
    message = format_log_message(data)

    # Log with appropriate level
    case level do
      :debug -> Logger.debug(message, reflection_data: enriched_data)
      :info -> Logger.info(message, reflection_data: enriched_data)
      :warning -> Logger.warning(message, reflection_data: enriched_data)
      :error -> Logger.error(message, reflection_data: enriched_data)
    end
  end

  defp format_log_message(data) do
    event = Map.get(data, :event, "reflection_event")
    process_id = Map.get(data, :process_id, "unknown")

    case event do
      "reflection_process_started" ->
        domain = Map.get(data, :domain_name, "unknown")
        "Reflection process started for domain '#{domain}' [#{process_id}]"

      "reflection_process_completed" ->
        success = Map.get(data, :success, false)
        status = if success, do: "successfully", else: "with errors"
        "Reflection process completed #{status} [#{process_id}]"

      "reflection_iteration_started" ->
        iteration = Map.get(data, :iteration, 0)
        stage = Map.get(data, :stage, "unknown")
        "Reflection iteration #{iteration} started (#{stage}) [#{process_id}]"

      "quality_evaluation_completed" ->
        iteration = Map.get(data, :iteration, 0)
        score = Map.get(data, :overall_score, 0.0)
        "Quality evaluation completed for iteration #{iteration}, score: #{Float.round(score, 3)} [#{process_id}]"

      "feedback_generated" ->
        iteration = Map.get(data, :iteration, 0)
        count = Map.get(data, :feedback_count, 0)
        "Generated #{count} feedback items for iteration #{iteration} [#{process_id}]"

      "refinement_applied" ->
        iteration = Map.get(data, :iteration, 0)
        count = Map.get(data, :improvements_count, 0)
        "Applied #{count} refinements for iteration #{iteration} [#{process_id}]"

      "iteration_control_decision" ->
        iteration = Map.get(data, :iteration, 0)
        decision = Map.get(data, :decision, :unknown)
        "Iteration control decision: #{decision} after iteration #{iteration} [#{process_id}]"

      "llm_interaction" ->
        operation = Map.get(data, :operation, :unknown)
        timing = Map.get(data, :timing_ms, 0)
        "LLM #{operation} completed in #{timing}ms [#{process_id}]"

      "reflection_error" ->
        stage = Map.get(data, :stage, :unknown)
        error_type = Map.get(data, :error_type, :unknown)
        "Reflection error in #{stage}: #{error_type} [#{process_id}]"

      "performance_warning" ->
        warning_type = Map.get(data, :warning_type, :unknown)
        "Performance warning: #{warning_type} [#{process_id}]"

      _ ->
        "Reflection event: #{event} [#{process_id}]"
    end
  end

  defp summarize_feedback(feedback) when is_list(feedback) do
    feedback
    |> Enum.take(3)  # Take first 3 items for summary
    |> Enum.map(fn
      item when is_binary(item) -> String.slice(item, 0, 50)
      item when is_map(item) -> Map.get(item, :summary, "feedback_item")
      _ -> "feedback_item"
    end)
  end

  defp calculate_data_size(data) when is_map(data) do
    data
    |> Jason.encode()
    |> case do
      {:ok, json} -> byte_size(json)
      {:error, _} -> 0
    end
  end
  defp calculate_data_size(_), do: 0

  defp classify_error(error) do
    cond do
      is_binary(error) -> :string_error
      is_atom(error) -> :atom_error
      match?({:error, _}, error) -> :tuple_error
      match?(%{__exception__: true}, error) -> :exception
      true -> :unknown_error
    end
  end

  defp format_error_message(error) do
    case error do
      error when is_binary(error) -> error
      error when is_atom(error) -> Atom.to_string(error)
      {:error, reason} -> inspect(reason)
      %{message: message} -> message
      error -> inspect(error)
    end
  end

  defp format_stacktrace(error) do
    case error do
      %{__stacktrace__: stacktrace} when is_list(stacktrace) ->
        stacktrace
        |> Enum.take(5)  # Limit stacktrace depth
        |> Enum.map(&Exception.format_stacktrace_entry/1)
      _ -> nil
    end
  end
end
