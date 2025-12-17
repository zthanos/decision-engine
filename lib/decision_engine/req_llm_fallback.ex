# lib/decision_engine/req_llm_fallback.ex
defmodule DecisionEngine.ReqLLMFallback do
  @moduledoc """
  Fallback mechanism for ReqLLM integration.

  This module provides fallback logic to gracefully handle failures
  and route requests to the legacy LLM implementation when needed.
  """

  require Logger

  @doc """
  Executes a function with ReqLLM, falling back to legacy implementation on failure.

  ## Parameters
  - reqllm_func: Function to execute with ReqLLM
  - legacy_func: Function to execute with legacy implementation
  - context: Map containing request context for feature flag evaluation

  ## Returns
  - Result from ReqLLM function if successful and enabled
  - Result from legacy function if ReqLLM is disabled or fails
  """
  @spec with_fallback(function(), function(), map()) :: term()
  def with_fallback(reqllm_func, legacy_func, context \\ %{}) do
    # Check if ReqLLM is enabled for this context
    if DecisionEngine.ReqLLMFeatureFlags.enabled?(context) do
      try do
        case reqllm_func.() do
          {:ok, result} ->
            Logger.debug("ReqLLM call successful")
            {:ok, result}

          {:error, reason} ->
            Logger.warning("ReqLLM call failed: #{inspect(reason)}")
            handle_reqllm_failure(legacy_func, context, reason)
        end
      rescue
        error ->
          Logger.error("ReqLLM call exception: #{inspect(error)}")
          handle_reqllm_failure(legacy_func, context, error)
      end
    else
      Logger.debug("ReqLLM disabled, using legacy implementation")
      legacy_func.()
    end
  end

  @doc """
  Executes a streaming function with ReqLLM, falling back to legacy implementation on failure.

  ## Parameters
  - reqllm_stream_func: Function to execute ReqLLM streaming
  - legacy_stream_func: Function to execute legacy streaming
  - context: Map containing request context for feature flag evaluation

  ## Returns
  - :ok if streaming started successfully
  - {:error, reason} if both implementations fail
  """
  @spec with_streaming_fallback(function(), function(), map()) :: :ok | {:error, term()}
  def with_streaming_fallback(reqllm_stream_func, legacy_stream_func, context \\ %{}) do
    # Add streaming operation type to context
    streaming_context = Map.put(context, :operation_type, :streaming)

    if DecisionEngine.ReqLLMFeatureFlags.enabled?(streaming_context) do
      try do
        case reqllm_stream_func.() do
          :ok ->
            Logger.debug("ReqLLM streaming started successfully")
            :ok

          {:error, reason} ->
            Logger.warning("ReqLLM streaming failed: #{inspect(reason)}")
            handle_streaming_failure(legacy_stream_func, streaming_context, reason)
        end
      rescue
        error ->
          Logger.error("ReqLLM streaming exception: #{inspect(error)}")
          handle_streaming_failure(legacy_stream_func, streaming_context, error)
      end
    else
      Logger.debug("ReqLLM streaming disabled, using legacy implementation")
      legacy_stream_func.()
    end
  end

  @doc """
  Checks if fallback should be used for the given context.

  ## Parameters
  - context: Map containing request context

  ## Returns
  - true if fallback should be used
  - false if ReqLLM should be attempted
  """
  @spec should_fallback?(map()) :: boolean()
  def should_fallback?(context \\ %{}) do
    not DecisionEngine.ReqLLMFeatureFlags.enabled?(context) or
    not DecisionEngine.ReqLLMFeatureFlags.fallback_enabled?()
  end

  @doc """
  Records a fallback event for monitoring and metrics.

  ## Parameters
  - reason: Atom or string describing the fallback reason
  - context: Map containing request context
  """
  @spec record_fallback(term(), map()) :: :ok
  def record_fallback(reason, context \\ %{}) do
    Logger.info("ReqLLM fallback triggered", %{
      reason: inspect(reason),
      context: context,
      timestamp: System.system_time(:millisecond)
    })

    # In a production system, you might want to send metrics to a monitoring system
    # For now, we'll just log the event
    :ok
  end

  # Private Functions

  defp handle_reqllm_failure(legacy_func, context, reason) do
    if DecisionEngine.ReqLLMFeatureFlags.fallback_enabled?() do
      Logger.info("Falling back to legacy implementation due to ReqLLM failure")
      record_fallback(reason, context)

      try do
        legacy_func.()
      rescue
        error ->
          Logger.error("Legacy fallback also failed: #{inspect(error)}")
          {:error, "Both ReqLLM and legacy implementations failed"}
      end
    else
      Logger.error("ReqLLM failed and fallback is disabled")
      {:error, "ReqLLM failed: #{inspect(reason)}"}
    end
  end

  defp handle_streaming_failure(legacy_stream_func, context, reason) do
    if DecisionEngine.ReqLLMFeatureFlags.fallback_enabled?() do
      Logger.info("Falling back to legacy streaming due to ReqLLM failure")
      record_fallback(reason, context)

      try do
        legacy_stream_func.()
      rescue
        error ->
          Logger.error("Legacy streaming fallback also failed: #{inspect(error)}")
          {:error, "Both ReqLLM and legacy streaming failed"}
      end
    else
      Logger.error("ReqLLM streaming failed and fallback is disabled")
      {:error, "ReqLLM streaming failed: #{inspect(reason)}"}
    end
  end
end
