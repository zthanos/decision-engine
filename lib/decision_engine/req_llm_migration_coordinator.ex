# lib/decision_engine/req_llm_migration_coordinator.ex
defmodule DecisionEngine.ReqLLMMigrationCoordinator do
  @moduledoc """
  Coordinates the migration between legacy LLM implementation and ReqLLM.

  This module acts as a routing layer that determines whether to use
  the legacy LLMClient or the new ReqLLMClient based on feature flags
  and migration phase.
  """

  require Logger

  alias DecisionEngine.LLMClient
  alias DecisionEngine.ReqLLMClient
  alias DecisionEngine.ReqLLMFeatureFlags
  alias DecisionEngine.ReqLLMPerformanceMonitor

  @doc """
  Routes LLM calls to appropriate implementation based on migration state.
  """
  @spec call_llm(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def call_llm(prompt, config) do
    context = %{
      provider: Map.get(config, :provider, :openai),
      operation_type: :non_streaming
    }

    start_time = System.monotonic_time(:millisecond)

    case should_use_reqllm?(context) do
      true ->
        Logger.debug("Routing non-streaming request to ReqLLM")

        case ReqLLMClient.call_llm(prompt, config) do
          {:ok, response} = result ->
            duration = System.monotonic_time(:millisecond) - start_time
            ReqLLMPerformanceMonitor.record_request(context.provider, :non_streaming, duration, true)
            result

          {:error, reason} = error ->
            duration = System.monotonic_time(:millisecond) - start_time
            ReqLLMPerformanceMonitor.record_request(context.provider, :non_streaming, duration, false)

            # Check if fallback is enabled
            if ReqLLMFeatureFlags.fallback_enabled?() do
              Logger.warning("ReqLLM failed, falling back to legacy: #{inspect(reason)}")
              fallback_to_legacy(:call_llm, [prompt, config], start_time, context)
            else
              error
            end
        end

      false ->
        Logger.debug("Routing non-streaming request to legacy LLMClient")
        fallback_to_legacy(:call_llm, [prompt, config], start_time, context)
    end
  end

  @doc """
  Routes streaming LLM calls to appropriate implementation.
  """
  @spec stream_llm(String.t(), map(), pid()) :: :ok | {:error, term()}
  def stream_llm(prompt, config, stream_pid) do
    context = %{
      provider: Map.get(config, :provider, :openai),
      operation_type: :streaming
    }

    start_time = System.monotonic_time(:millisecond)

    case should_use_reqllm?(context) do
      true ->
        Logger.debug("Routing streaming request to ReqLLM")

        case ReqLLMClient.stream_llm(prompt, config, stream_pid) do
          :ok = result ->
            # Note: streaming duration will be recorded when stream completes
            result

          {:error, reason} = error ->
            duration = System.monotonic_time(:millisecond) - start_time
            ReqLLMPerformanceMonitor.record_streaming_event(context.provider, false, duration)

            # Check if fallback is enabled
            if ReqLLMFeatureFlags.fallback_enabled?() do
              Logger.warning("ReqLLM streaming failed, falling back to legacy: #{inspect(reason)}")
              fallback_to_legacy_streaming(prompt, config, stream_pid, start_time, context)
            else
              error
            end
        end

      false ->
        Logger.debug("Routing streaming request to legacy LLMClient")
        fallback_to_legacy_streaming(prompt, config, stream_pid, start_time, context)
    end
  end

  @doc """
  Routes signal extraction to appropriate implementation.
  """
  @spec extract_signals(String.t(), map(), atom(), module(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def extract_signals(user_scenario, config, domain, schema_module, rule_config, retry_count \\ 0) do
    context = %{
      provider: Map.get(config, :provider, :openai),
      operation_type: :non_streaming
    }

    start_time = System.monotonic_time(:millisecond)

    case should_use_reqllm?(context) do
      true ->
        Logger.debug("Routing signal extraction to ReqLLM")

        # ReqLLMClient doesn't have extract_signals yet, so use legacy for now
        # This will be implemented in a future phase
        Logger.debug("Signal extraction not yet implemented in ReqLLM, using legacy")
        fallback_to_legacy(:extract_signals, [user_scenario, config, domain, schema_module, rule_config, retry_count], start_time, context)

      false ->
        Logger.debug("Routing signal extraction to legacy LLMClient")
        fallback_to_legacy(:extract_signals, [user_scenario, config, domain, schema_module, rule_config, retry_count], start_time, context)
    end
  end

  @doc """
  Routes justification generation to appropriate implementation.
  """
  @spec generate_justification(map(), map(), map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def generate_justification(signals, decision_result, config, domain) do
    context = %{
      provider: Map.get(config, :provider, :openai),
      operation_type: :non_streaming
    }

    start_time = System.monotonic_time(:millisecond)

    case should_use_reqllm?(context) do
      true ->
        Logger.debug("Routing justification generation to ReqLLM")

        # ReqLLMClient doesn't have generate_justification yet, so use legacy for now
        Logger.debug("Justification generation not yet implemented in ReqLLM, using legacy")
        fallback_to_legacy(:generate_justification, [signals, decision_result, config, domain], start_time, context)

      false ->
        Logger.debug("Routing justification generation to legacy LLMClient")
        fallback_to_legacy(:generate_justification, [signals, decision_result, config, domain], start_time, context)
    end
  end

  @doc """
  Routes streaming justification to appropriate implementation.
  """
  @spec stream_justification(map(), map(), map(), atom(), pid()) :: :ok | {:error, term()}
  def stream_justification(signals, decision_result, config, domain, stream_pid) do
    context = %{
      provider: Map.get(config, :provider, :openai),
      operation_type: :streaming
    }

    start_time = System.monotonic_time(:millisecond)

    case should_use_reqllm?(context) do
      true ->
        Logger.debug("Routing streaming justification to ReqLLM")

        # ReqLLMClient doesn't have stream_justification yet, so use legacy for now
        Logger.debug("Streaming justification not yet implemented in ReqLLM, using legacy")
        fallback_to_legacy_streaming_justification(signals, decision_result, config, domain, stream_pid, start_time, context)

      false ->
        Logger.debug("Routing streaming justification to legacy LLMClient")
        fallback_to_legacy_streaming_justification(signals, decision_result, config, domain, stream_pid, start_time, context)
    end
  end

  @doc """
  Routes general text generation to appropriate implementation.
  """
  @spec generate_text(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def generate_text(prompt, config \\ nil) do
    # Use unified config if none provided
    final_config = case config do
      nil ->
        case LLMClient.get_unified_config(nil) do
          {:ok, unified_config} -> unified_config
          {:error, _} -> %{provider: :openai}  # fallback
        end
      config -> config
    end

    context = %{
      provider: Map.get(final_config, :provider, :openai),
      operation_type: :non_streaming
    }

    start_time = System.monotonic_time(:millisecond)

    case should_use_reqllm?(context) do
      true ->
        Logger.debug("Routing text generation to ReqLLM")

        case ReqLLMClient.call_llm(prompt, final_config) do
          {:ok, response} = result ->
            duration = System.monotonic_time(:millisecond) - start_time
            ReqLLMPerformanceMonitor.record_request(context.provider, :non_streaming, duration, true)
            result

          {:error, reason} = error ->
            duration = System.monotonic_time(:millisecond) - start_time
            ReqLLMPerformanceMonitor.record_request(context.provider, :non_streaming, duration, false)

            # Check if fallback is enabled
            if ReqLLMFeatureFlags.fallback_enabled?() do
              Logger.warning("ReqLLM text generation failed, falling back to legacy: #{inspect(reason)}")
              fallback_to_legacy(:generate_text, [prompt, config], start_time, context)
            else
              error
            end
        end

      false ->
        Logger.debug("Routing text generation to legacy LLMClient")
        fallback_to_legacy(:generate_text, [prompt, config], start_time, context)
    end
  end

  # Private Functions

  defp should_use_reqllm?(context) do
    # Check rollout percentage first
    session_id = generate_session_identifier()

    case ReqLLMFeatureFlags.in_rollout?(session_id) do
      true ->
        # Check if ReqLLM is enabled for this specific context
        ReqLLMFeatureFlags.enabled?(context)

      false ->
        false
    end
  end

  defp generate_session_identifier() do
    # Generate a consistent identifier for rollout decisions
    # In a real system, this might be based on user ID, session ID, etc.
    # For now, we'll use a combination of process ID and timestamp
    pid_string = inspect(self())
    timestamp = System.system_time(:second)

    :crypto.hash(:md5, "#{pid_string}_#{timestamp}")
    |> Base.encode16()
    |> String.slice(0, 8)
  end

  defp fallback_to_legacy(function, args, start_time, context) do
    case apply(LLMClient, function, args) do
      {:ok, response} = result ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_request(context.provider, context.operation_type, duration, true)
        result

      {:error, reason} = error ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_request(context.provider, context.operation_type, duration, false)
        error
    end
  end

  defp fallback_to_legacy_streaming(prompt, config, stream_pid, start_time, context) do
    # Create a wrapper process to monitor streaming completion
    wrapper_pid = spawn_link(fn ->
      monitor_streaming_completion(stream_pid, start_time, context)
    end)

    # Use legacy streaming with monitoring
    case LLMClient.call_llm_stream(prompt, config, wrapper_pid) do
      :ok = result ->
        result

      {:error, reason} = error ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_streaming_event(context.provider, false, duration)
        error
    end
  end

  defp fallback_to_legacy_streaming_justification(signals, decision_result, config, domain, stream_pid, start_time, context) do
    # Create a wrapper process to monitor streaming completion
    wrapper_pid = spawn_link(fn ->
      monitor_streaming_completion(stream_pid, start_time, context)
    end)

    # Use legacy streaming justification with monitoring
    case LLMClient.stream_justification(signals, decision_result, config, domain, wrapper_pid) do
      :ok = result ->
        result

      {:error, reason} = error ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_streaming_event(context.provider, false, duration)
        error
    end
  end

  defp monitor_streaming_completion(target_pid, start_time, context) do
    receive do
      {:chunk, content} ->
        send(target_pid, {:chunk, content})
        monitor_streaming_completion(target_pid, start_time, context)

      {:complete} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_streaming_event(context.provider, true, duration)
        send(target_pid, {:complete})

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_streaming_event(context.provider, false, duration)
        send(target_pid, {:error, reason})

      other ->
        # Forward any other messages
        send(target_pid, other)
        monitor_streaming_completion(target_pid, start_time, context)
    after
      300_000 ->  # 5 minute timeout
        duration = System.monotonic_time(:millisecond) - start_time
        ReqLLMPerformanceMonitor.record_streaming_event(context.provider, false, duration)
        send(target_pid, {:error, :timeout})
    end
  end
end
