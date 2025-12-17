defmodule DecisionEngine.ReqLLMReconnectionManager do
  @moduledoc """
  Manages automatic reconnection and stream resumption for ReqLLM streaming sessions.

  This module provides sophisticated reconnection capabilities including:
  - Network interruption detection
  - Automatic reconnection with exponential backoff
  - Stream resumption where supported by APIs
  - Connection health monitoring
  - Graceful degradation strategies
  """

  use GenServer
  require Logger

  @typedoc """
  Reconnection session state.
  """
  @type reconnection_session :: %{
    session_id: String.t(),
    original_config: map(),
    original_prompt: String.t(),
    stream_pid: pid(),
    reconnection_state: %{
      enabled: boolean(),
      max_attempts: integer(),
      current_attempt: integer(),
      backoff_strategy: :exponential | :linear | :constant,
      base_delay_ms: integer(),
      max_delay_ms: integer(),
      last_attempt_time: integer(),
      total_reconnection_time: integer()
    },
    interruption_detection: %{
      last_chunk_time: integer(),
      chunk_timeout_ms: integer(),
      heartbeat_interval_ms: integer(),
      missed_heartbeats: integer(),
      max_missed_heartbeats: integer()
    },
    resumption_support: %{
      provider_supports_resumption: boolean(),
      last_successful_position: integer(),
      accumulated_content: String.t(),
      resumption_token: String.t() | nil
    },
    health_monitoring: %{
      connection_quality: :excellent | :good | :poor | :critical,
      latency_ms: float(),
      error_rate: float(),
      consecutive_failures: integer()
    }
  }

  # Configuration constants
  @default_max_attempts 5
  @default_base_delay_ms 1000
  @default_max_delay_ms 30000
  @default_chunk_timeout_ms 10000
  @default_heartbeat_interval_ms 5000
  @default_max_missed_heartbeats 3

  ## Public API

  @doc """
  Starts reconnection management for a streaming session.

  ## Parameters
  - session_id: Unique identifier for the streaming session
  - config: Original ReqLLM configuration
  - prompt: Original prompt for resumption
  - stream_pid: Process to receive reconnection events
  - opts: Reconnection options

  ## Returns
  - {:ok, pid} on successful start
  - {:error, reason} if start fails
  """
  @spec start_link(String.t(), map(), String.t(), pid(), keyword()) :: GenServer.on_start()
  def start_link(session_id, config, prompt, stream_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {session_id, config, prompt, stream_pid, opts},
                        name: via_tuple(session_id))
  end

  @doc """
  Reports a network interruption for a session.

  ## Parameters
  - session_id: The session experiencing interruption
  - interruption_type: Type of interruption (:timeout, :connection_lost, :error)
  - context: Additional context about the interruption

  ## Returns
  - :ok if interruption reported successfully
  - {:error, :not_found} if session doesn't exist
  """
  @spec report_interruption(String.t(), atom(), map()) :: :ok | {:error, :not_found}
  def report_interruption(session_id, interruption_type, context \\ %{}) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:report_interruption, interruption_type, context})
    end
  end

  @doc """
  Reports successful chunk reception to update health monitoring.

  ## Parameters
  - session_id: The session receiving chunks
  - chunk_info: Information about the received chunk

  ## Returns
  - :ok if reported successfully
  - {:error, :not_found} if session doesn't exist
  """
  @spec report_chunk_received(String.t(), map()) :: :ok | {:error, :not_found}
  def report_chunk_received(session_id, chunk_info \\ %{}) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:chunk_received, chunk_info})
    end
  end

  @doc """
  Forces a reconnection attempt for a session.

  ## Parameters
  - session_id: The session to reconnect

  ## Returns
  - :ok if reconnection initiated
  - {:error, :not_found} if session doesn't exist
  """
  @spec force_reconnection(String.t()) :: :ok | {:error, :not_found}
  def force_reconnection(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, :force_reconnection)
    end
  end

  @doc """
  Gets reconnection status and health metrics for a session.

  ## Parameters
  - session_id: The session to check

  ## Returns
  - {:ok, status} with reconnection and health information
  - {:error, :not_found} if session doesn't exist
  """
  @spec get_reconnection_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_reconnection_status(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_reconnection_status)
    end
  end

  ## GenServer Callbacks

  @impl true
  def init({session_id, config, prompt, stream_pid, opts}) do
    # Set up process monitoring
    Process.monitor(stream_pid)

    # Initialize reconnection session
    session = %{
      session_id: session_id,
      original_config: config,
      original_prompt: prompt,
      stream_pid: stream_pid,
      reconnection_state: %{
        enabled: Keyword.get(opts, :enable_reconnection, true),
        max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
        current_attempt: 0,
        backoff_strategy: Keyword.get(opts, :backoff_strategy, :exponential),
        base_delay_ms: Keyword.get(opts, :base_delay_ms, @default_base_delay_ms),
        max_delay_ms: Keyword.get(opts, :max_delay_ms, @default_max_delay_ms),
        last_attempt_time: 0,
        total_reconnection_time: 0
      },
      interruption_detection: %{
        last_chunk_time: System.monotonic_time(:millisecond),
        chunk_timeout_ms: Keyword.get(opts, :chunk_timeout_ms, @default_chunk_timeout_ms),
        heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms),
        missed_heartbeats: 0,
        max_missed_heartbeats: Keyword.get(opts, :max_missed_heartbeats, @default_max_missed_heartbeats)
      },
      resumption_support: %{
        provider_supports_resumption: supports_resumption?(config.provider),
        last_successful_position: 0,
        accumulated_content: "",
        resumption_token: nil
      },
      health_monitoring: %{
        connection_quality: :excellent,
        latency_ms: 0.0,
        error_rate: 0.0,
        consecutive_failures: 0
      }
    }

    # Start health monitoring
    schedule_health_check(session.interruption_detection.heartbeat_interval_ms)

    Logger.info("ReqLLMReconnectionManager started for session #{session_id}")

    {:ok, session}
  end

  @impl true
  def handle_cast({:report_interruption, interruption_type, context}, session) do
    Logger.warning("Network interruption reported for session #{session.session_id}: #{interruption_type}")

    # Update health monitoring
    updated_health = update_health_on_interruption(session.health_monitoring, interruption_type)

    # Check if reconnection should be attempted
    if should_attempt_reconnection?(session, interruption_type) do
      # Schedule reconnection attempt
      delay = calculate_reconnection_delay(session.reconnection_state)
      schedule_reconnection_attempt(delay)

      # Update reconnection state
      updated_reconnection_state = %{session.reconnection_state |
        current_attempt: session.reconnection_state.current_attempt + 1,
        last_attempt_time: System.monotonic_time(:millisecond)
      }

      # Send interruption notification
      send_reconnection_event(session.stream_pid, "interruption_detected", %{
        session_id: session.session_id,
        interruption_type: interruption_type,
        context: context,
        reconnection_scheduled: true,
        delay_ms: delay,
        attempt: updated_reconnection_state.current_attempt,
        max_attempts: session.reconnection_state.max_attempts
      })

      updated_session = %{session |
        reconnection_state: updated_reconnection_state,
        health_monitoring: updated_health
      }

      {:noreply, updated_session}
    else
      # Reconnection not possible or disabled
      send_reconnection_event(session.stream_pid, "reconnection_failed", %{
        session_id: session.session_id,
        reason: :max_attempts_reached,
        total_attempts: session.reconnection_state.current_attempt,
        total_reconnection_time: session.reconnection_state.total_reconnection_time
      })

      {:stop, :normal, session}
    end
  end

  @impl true
  def handle_cast({:chunk_received, chunk_info}, session) do
    current_time = System.monotonic_time(:millisecond)

    # Update interruption detection
    updated_interruption_detection = %{session.interruption_detection |
      last_chunk_time: current_time,
      missed_heartbeats: 0
    }

    # Update health monitoring
    latency = Map.get(chunk_info, :latency_ms, 0.0)
    updated_health = update_health_on_success(session.health_monitoring, latency)

    # Update resumption support if applicable
    updated_resumption = update_resumption_state(session.resumption_support, chunk_info)

    # Reset reconnection state on successful chunk
    updated_reconnection_state = %{session.reconnection_state |
      current_attempt: 0,
      total_reconnection_time: 0
    }

    updated_session = %{session |
      interruption_detection: updated_interruption_detection,
      health_monitoring: updated_health,
      resumption_support: updated_resumption,
      reconnection_state: updated_reconnection_state
    }

    {:noreply, updated_session}
  end

  @impl true
  def handle_cast(:force_reconnection, session) do
    Logger.info("Forcing reconnection for session #{session.session_id}")

    # Immediately attempt reconnection
    attempt_reconnection(session)
  end

  @impl true
  def handle_call(:get_reconnection_status, _from, session) do
    status = %{
      session_id: session.session_id,
      reconnection_enabled: session.reconnection_state.enabled,
      current_attempt: session.reconnection_state.current_attempt,
      max_attempts: session.reconnection_state.max_attempts,
      connection_quality: session.health_monitoring.connection_quality,
      latency_ms: session.health_monitoring.latency_ms,
      error_rate: session.health_monitoring.error_rate,
      provider_supports_resumption: session.resumption_support.provider_supports_resumption,
      last_chunk_time: session.interruption_detection.last_chunk_time,
      missed_heartbeats: session.interruption_detection.missed_heartbeats
    }

    {:reply, {:ok, status}, session}
  end

  @impl true
  def handle_info(:health_check, session) do
    current_time = System.monotonic_time(:millisecond)
    time_since_last_chunk = current_time - session.interruption_detection.last_chunk_time

    # Check for chunk timeout
    if time_since_last_chunk > session.interruption_detection.chunk_timeout_ms do
      # Increment missed heartbeats
      updated_interruption_detection = %{session.interruption_detection |
        missed_heartbeats: session.interruption_detection.missed_heartbeats + 1
      }

      # Check if we've exceeded the threshold
      if updated_interruption_detection.missed_heartbeats >= session.interruption_detection.max_missed_heartbeats do
        Logger.warning("Health check failed for session #{session.session_id}: #{updated_interruption_detection.missed_heartbeats} missed heartbeats")

        # Report interruption
        GenServer.cast(self(), {:report_interruption, :health_check_timeout, %{
          missed_heartbeats: updated_interruption_detection.missed_heartbeats,
          time_since_last_chunk: time_since_last_chunk
        }})

        updated_session = %{session | interruption_detection: updated_interruption_detection}
        {:noreply, updated_session}
      else
        # Schedule next health check
        schedule_health_check(session.interruption_detection.heartbeat_interval_ms)

        updated_session = %{session | interruption_detection: updated_interruption_detection}
        {:noreply, updated_session}
      end
    else
      # Health check passed, schedule next one
      schedule_health_check(session.interruption_detection.heartbeat_interval_ms)
      {:noreply, session}
    end
  end

  @impl true
  def handle_info(:attempt_reconnection, session) do
    Logger.info("Attempting reconnection #{session.reconnection_state.current_attempt}/#{session.reconnection_state.max_attempts} for session #{session.session_id}")

    case attempt_reconnection(session) do
      {:ok, updated_session} -> {:noreply, updated_session}
      {:error, _reason} -> {:stop, :reconnection_failed, session}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, session) do
    Logger.info("Stream process down for session #{session.session_id}: #{inspect(reason)}")
    {:stop, :normal, session}
  end

  ## Private Functions

  # Determine if provider supports stream resumption
  defp supports_resumption?(provider) do
    case provider do
      :openai -> false  # OpenAI doesn't support resumption
      :anthropic -> false  # Anthropic doesn't support resumption
      :ollama -> false  # Ollama doesn't support resumption
      :openrouter -> false  # OpenRouter doesn't support resumption
      :lm_studio -> false  # LM Studio doesn't support resumption
      :custom -> false  # Assume custom providers don't support resumption
      _ -> false
    end
  end

  # Check if reconnection should be attempted
  defp should_attempt_reconnection?(session, interruption_type) do
    reconnection_state = session.reconnection_state

    # Check if reconnection is enabled
    cond do
      not reconnection_state.enabled ->
        false
      # Check if we've exceeded max attempts
      reconnection_state.current_attempt >= reconnection_state.max_attempts ->
        false
      # Check if interruption type is recoverable
      not is_recoverable_interruption?(interruption_type) ->
        false
      true ->
        true
    end
  end

  # Determine if interruption type is recoverable
  defp is_recoverable_interruption?(interruption_type) do
    case interruption_type do
      :timeout -> true
      :connection_lost -> true
      :health_check_timeout -> true
      :network_error -> true
      :http_error -> true
      :rate_limit -> true
      :server_error -> true
      :authentication_error -> false  # Not recoverable
      :invalid_request -> false  # Not recoverable
      :quota_exceeded -> false  # Not recoverable
      _ -> true  # Default to recoverable for unknown types
    end
  end

  # Calculate reconnection delay based on strategy
  defp calculate_reconnection_delay(reconnection_state) do
    case reconnection_state.backoff_strategy do
      :exponential ->
        delay = reconnection_state.base_delay_ms * :math.pow(2, reconnection_state.current_attempt - 1)
        min(trunc(delay), reconnection_state.max_delay_ms)

      :linear ->
        delay = reconnection_state.base_delay_ms * reconnection_state.current_attempt
        min(delay, reconnection_state.max_delay_ms)

      :constant ->
        reconnection_state.base_delay_ms
    end
  end

  # Update health monitoring on interruption
  defp update_health_on_interruption(health_monitoring, interruption_type) do
    # Increase consecutive failures
    consecutive_failures = health_monitoring.consecutive_failures + 1

    # Update error rate (simple moving average)
    new_error_rate = min(health_monitoring.error_rate + 0.1, 1.0)

    # Determine connection quality based on failures and error rate
    connection_quality = case {consecutive_failures, new_error_rate} do
      {failures, _} when failures >= 5 -> :critical
      {failures, rate} when failures >= 3 or rate > 0.5 -> :poor
      {failures, rate} when failures >= 1 or rate > 0.2 -> :good
      _ -> :excellent
    end

    %{health_monitoring |
      consecutive_failures: consecutive_failures,
      error_rate: new_error_rate,
      connection_quality: connection_quality
    }
  end

  # Update health monitoring on successful chunk
  defp update_health_on_success(health_monitoring, latency) do
    # Reset consecutive failures
    consecutive_failures = 0

    # Update error rate (decay towards 0)
    new_error_rate = max(health_monitoring.error_rate - 0.05, 0.0)

    # Update latency (simple moving average)
    new_latency = if health_monitoring.latency_ms == 0.0 do
      latency
    else
      (health_monitoring.latency_ms * 0.8) + (latency * 0.2)
    end

    # Determine connection quality
    connection_quality = case {new_error_rate, new_latency} do
      {rate, lat} when rate < 0.1 and lat < 100 -> :excellent
      {rate, lat} when rate < 0.2 and lat < 500 -> :good
      {rate, lat} when rate < 0.5 and lat < 1000 -> :poor
      _ -> :critical
    end

    %{health_monitoring |
      consecutive_failures: consecutive_failures,
      error_rate: new_error_rate,
      latency_ms: new_latency,
      connection_quality: connection_quality
    }
  end

  # Update resumption state with chunk information
  defp update_resumption_state(resumption_support, chunk_info) do
    # Update accumulated content if provided
    new_content = case Map.get(chunk_info, :content) do
      nil -> resumption_support.accumulated_content
      content -> resumption_support.accumulated_content <> content
    end

    # Update position if provided
    new_position = Map.get(chunk_info, :position, resumption_support.last_successful_position + 1)

    # Update resumption token if provided
    new_token = Map.get(chunk_info, :resumption_token, resumption_support.resumption_token)

    %{resumption_support |
      last_successful_position: new_position,
      accumulated_content: new_content,
      resumption_token: new_token
    }
  end

  # Attempt reconnection
  defp attempt_reconnection(session) do
    start_time = System.monotonic_time(:millisecond)

    # Send reconnection attempt notification
    send_reconnection_event(session.stream_pid, "reconnection_attempt", %{
      session_id: session.session_id,
      attempt: session.reconnection_state.current_attempt,
      max_attempts: session.reconnection_state.max_attempts,
      connection_quality: session.health_monitoring.connection_quality
    })

    # Attempt to restart streaming
    case attempt_stream_restart(session) do
      {:ok, _stream_ref} ->
        end_time = System.monotonic_time(:millisecond)
        reconnection_time = end_time - start_time

        Logger.info("Reconnection successful for session #{session.session_id} in #{reconnection_time}ms")

        # Send success notification
        send_reconnection_event(session.stream_pid, "reconnection_success", %{
          session_id: session.session_id,
          attempt: session.reconnection_state.current_attempt,
          reconnection_time_ms: reconnection_time,
          resumed_from_position: session.resumption_support.last_successful_position
        })

        # Reset reconnection state
        updated_reconnection_state = %{session.reconnection_state |
          current_attempt: 0,
          total_reconnection_time: session.reconnection_state.total_reconnection_time + reconnection_time
        }

        # Reset health monitoring
        updated_health = %{session.health_monitoring |
          consecutive_failures: 0,
          connection_quality: :good
        }

        updated_session = %{session |
          reconnection_state: updated_reconnection_state,
          health_monitoring: updated_health
        }

        {:ok, updated_session}

      {:error, reason} ->
        end_time = System.monotonic_time(:millisecond)
        reconnection_time = end_time - start_time

        Logger.error("Reconnection failed for session #{session.session_id}: #{inspect(reason)}")

        # Check if we should try again
        if session.reconnection_state.current_attempt < session.reconnection_state.max_attempts do
          # Schedule next attempt
          delay = calculate_reconnection_delay(session.reconnection_state)
          schedule_reconnection_attempt(delay)

          # Update state for next attempt
          updated_reconnection_state = %{session.reconnection_state |
            current_attempt: session.reconnection_state.current_attempt + 1,
            total_reconnection_time: session.reconnection_state.total_reconnection_time + reconnection_time
          }

          send_reconnection_event(session.stream_pid, "reconnection_retry", %{
            session_id: session.session_id,
            failed_attempt: session.reconnection_state.current_attempt,
            next_attempt: updated_reconnection_state.current_attempt,
            max_attempts: session.reconnection_state.max_attempts,
            next_attempt_in_ms: delay,
            error: reason
          })

          updated_session = %{session | reconnection_state: updated_reconnection_state}
          {:ok, updated_session}
        else
          # Max attempts reached
          send_reconnection_event(session.stream_pid, "reconnection_failed", %{
            session_id: session.session_id,
            reason: :max_attempts_reached,
            total_attempts: session.reconnection_state.current_attempt,
            total_reconnection_time: session.reconnection_state.total_reconnection_time + reconnection_time,
            final_error: reason
          })

          {:error, :max_attempts_reached}
        end
    end
  end

  # Attempt to restart streaming
  defp attempt_stream_restart(session) do
    try do
      # Use ReqLLMClient to restart streaming
      case DecisionEngine.ReqLLMClient.stream_llm(
        session.original_prompt,
        session.original_config,
        session.stream_pid
      ) do
        {:ok, stream_ref} ->
          {:ok, stream_ref}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        {:error, {:exception, error}}
    end
  end

  # Send reconnection event to stream process
  defp send_reconnection_event(stream_pid, event_type, data) do
    send(stream_pid, {:sse_event, event_type, data})
  end

  # Schedule health check
  defp schedule_health_check(interval_ms) do
    Process.send_after(self(), :health_check, interval_ms)
  end

  # Schedule reconnection attempt
  defp schedule_reconnection_attempt(delay_ms) do
    Process.send_after(self(), :attempt_reconnection, delay_ms)
  end

  # Registry via tuple for session management
  defp via_tuple(session_id) do
    {:via, Registry, {DecisionEngine.StreamRegistry, "reconnection_#{session_id}"}}
  end
end
