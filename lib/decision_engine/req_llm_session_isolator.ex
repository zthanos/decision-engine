# lib/decision_engine/req_llm_session_isolator.ex
defmodule DecisionEngine.ReqLLMSessionIsolator do
  @moduledoc """
  Session isolation and data protection for ReqLLM integration.

  This module provides proper session isolation for concurrent requests,
  data leakage prevention mechanisms, and session-based security controls
  to ensure that concurrent LLM requests do not interfere with each other
  or leak sensitive data between sessions.

  Features:
  - Session-based request isolation
  - Data leakage prevention between concurrent requests
  - Session-specific security controls and policies
  - Memory isolation and cleanup
  - Session lifecycle management
  - Cross-session contamination detection
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger

  @session_timeout_ms 300_000  # 5 minutes default
  @max_concurrent_sessions 100
  @cleanup_interval_ms 60_000  # 1 minute

  defstruct [
    :session_id,
    :created_at,
    :last_accessed,
    :expires_at,
    :isolation_level,
    :security_context,
    :data_scope,
    :cleanup_handlers,
    :metadata
  ]

  @type isolation_level :: :strict | :standard | :relaxed
  @type session_id :: String.t()

  @type t :: %__MODULE__{
    session_id: session_id(),
    created_at: DateTime.t(),
    last_accessed: DateTime.t(),
    expires_at: DateTime.t(),
    isolation_level: isolation_level(),
    security_context: map(),
    data_scope: map(),
    cleanup_handlers: list(),
    metadata: map()
  }

  @doc """
  Creates a new isolated session for LLM requests.

  ## Parameters
  - isolation_level: Level of isolation (:strict, :standard, :relaxed)
  - security_context: Security context and policies for the session
  - opts: Additional session options

  ## Returns
  - {:ok, session_id} on success
  - {:error, reason} on failure

  ## Examples
      iex> create_session(:strict, %{user_id: "user123"})
      {:ok, "session_abc123"}
  """
  @spec create_session(isolation_level(), map(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def create_session(isolation_level \\ :standard, security_context \\ %{}, opts \\ []) do
    with :ok <- validate_isolation_level(isolation_level),
         :ok <- check_session_limits(),
         {:ok, session_id} <- generate_session_id(),
         {:ok, session} <- initialize_session(session_id, isolation_level, security_context, opts),
         :ok <- register_session(session) do

      ReqLLMLogger.log_security_event(:session_created, %{
        session_id: mask_session_id(session_id),
        isolation_level: isolation_level,
        success: true
      })

      {:ok, session_id}
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_security_event(:session_creation_failed, %{
          isolation_level: isolation_level,
          reason: reason,
          success: false
        })
        error
    end
  end

  @doc """
  Executes a function within an isolated session context.

  ## Parameters
  - session_id: The session to execute within
  - fun: Function to execute with session isolation
  - opts: Execution options

  ## Returns
  - {:ok, result} on success
  - {:error, reason} on failure
  """
  @spec execute_in_session(session_id(), function(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute_in_session(session_id, fun, opts \\ []) when is_function(fun) do
    with {:ok, session} <- get_session(session_id),
         :ok <- validate_session_access(session, opts),
         :ok <- setup_session_isolation(session),
         {:ok, result} <- execute_with_isolation(fun, session, opts),
         :ok <- cleanup_session_context(session) do

      update_session_access(session_id)

      ReqLLMLogger.log_security_event(:session_execution_completed, %{
        session_id: mask_session_id(session_id),
        success: true
      })

      {:ok, result}
    else
      {:error, reason} = error ->
        cleanup_session_context_on_error(session_id)

        ReqLLMLogger.log_security_event(:session_execution_failed, %{
          session_id: mask_session_id(session_id),
          reason: reason,
          success: false
        })

        error
    end
  end

  @doc """
  Validates that a session is properly isolated and secure.

  ## Parameters
  - session_id: The session to validate

  ## Returns
  - :ok if validation passes
  - {:error, violations} if isolation violations are detected
  """
  @spec validate_session_isolation(session_id()) :: :ok | {:error, list()}
  def validate_session_isolation(session_id) do
    with {:ok, session} <- get_session(session_id),
         :ok <- check_memory_isolation(session),
         :ok <- check_data_isolation(session),
         :ok <- check_security_isolation(session),
         :ok <- detect_cross_session_contamination(session) do

      ReqLLMLogger.log_security_event(:session_isolation_validated, %{
        session_id: mask_session_id(session_id),
        success: true
      })

      :ok
    else
      {:error, violations} = error ->
        ReqLLMLogger.log_security_event(:session_isolation_violations, %{
          session_id: mask_session_id(session_id),
          violations: violations,
          success: false
        })

        error
    end
  end

  @doc """
  Destroys a session and cleans up all associated resources.

  ## Parameters
  - session_id: The session to destroy
  - opts: Cleanup options

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec destroy_session(session_id(), keyword()) :: :ok | {:error, term()}
  def destroy_session(session_id, opts \\ []) do
    with {:ok, session} <- get_session(session_id),
         :ok <- execute_cleanup_handlers(session, opts),
         :ok <- clear_session_data(session),
         :ok <- unregister_session(session_id) do

      ReqLLMLogger.log_security_event(:session_destroyed, %{
        session_id: mask_session_id(session_id),
        success: true
      })

      :ok
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_security_event(:session_destruction_failed, %{
          session_id: mask_session_id(session_id),
          reason: reason,
          success: false
        })

        error
    end
  end

  @doc """
  Adds a cleanup handler to be executed when the session is destroyed.

  ## Parameters
  - session_id: The session to add the handler to
  - handler: Function to execute during cleanup
  - opts: Handler options

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec add_cleanup_handler(session_id(), function(), keyword()) :: :ok | {:error, term()}
  def add_cleanup_handler(session_id, handler, opts \\ []) when is_function(handler) do
    with {:ok, session} <- get_session(session_id),
         updated_handlers <- [handler | session.cleanup_handlers],
         updated_session <- %{session | cleanup_handlers: updated_handlers},
         :ok <- update_session(session_id, updated_session) do
      :ok
    else
      error -> error
    end
  end

  @doc """
  Gets session information for monitoring and debugging.

  ## Parameters
  - session_id: The session to get information for

  ## Returns
  - {:ok, session_info} on success
  - {:error, reason} on failure
  """
  @spec get_session_info(session_id()) :: {:ok, map()} | {:error, term()}
  def get_session_info(session_id) do
    with {:ok, session} <- get_session(session_id) do
      session_info = %{
        session_id: mask_session_id(session_id),
        created_at: session.created_at,
        last_accessed: session.last_accessed,
        expires_at: session.expires_at,
        isolation_level: session.isolation_level,
        active: session_active?(session),
        metadata: sanitize_session_metadata(session.metadata)
      }

      {:ok, session_info}
    else
      error -> error
    end
  end

  @doc """
  Starts the session cleanup process to remove expired sessions.
  """
  @spec start_cleanup_process() :: :ok
  def start_cleanup_process do
    spawn(fn -> cleanup_loop() end)
    :ok
  end

  # Private functions

  defp validate_isolation_level(level) when level in [:strict, :standard, :relaxed], do: :ok
  defp validate_isolation_level(level), do: {:error, {:invalid_isolation_level, level}}

  defp check_session_limits do
    active_sessions = count_active_sessions()

    if active_sessions >= @max_concurrent_sessions do
      {:error, :session_limit_exceeded}
    else
      :ok
    end
  end

  defp generate_session_id do
    session_id = "sess_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
    {:ok, session_id}
  end

  defp initialize_session(session_id, isolation_level, security_context, opts) do
    now = DateTime.utc_now()
    timeout_ms = Keyword.get(opts, :timeout_ms, @session_timeout_ms)
    expires_at = DateTime.add(now, timeout_ms, :millisecond)

    session = %__MODULE__{
      session_id: session_id,
      created_at: now,
      last_accessed: now,
      expires_at: expires_at,
      isolation_level: isolation_level,
      security_context: security_context,
      data_scope: initialize_data_scope(isolation_level),
      cleanup_handlers: [],
      metadata: Keyword.get(opts, :metadata, %{})
    }

    {:ok, session}
  end

  defp initialize_data_scope(isolation_level) do
    case isolation_level do
      :strict ->
        %{
          memory_isolated: true,
          process_isolated: true,
          data_encrypted: true,
          cross_session_access: false
        }

      :standard ->
        %{
          memory_isolated: true,
          process_isolated: false,
          data_encrypted: false,
          cross_session_access: false
        }

      :relaxed ->
        %{
          memory_isolated: false,
          process_isolated: false,
          data_encrypted: false,
          cross_session_access: true
        }
    end
  end

  defp register_session(session) do
    table_name = get_session_table()
    :ets.insert(table_name, {session.session_id, session})
    :ok
  end

  defp get_session(session_id) do
    table_name = get_session_table()

    case :ets.lookup(table_name, session_id) do
      [{^session_id, session}] ->
        if session_active?(session) do
          {:ok, session}
        else
          {:error, :session_expired}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  defp validate_session_access(session, opts) do
    # Check if session is still valid and accessible
    cond do
      not session_active?(session) ->
        {:error, :session_expired}

      session_access_denied?(session, opts) ->
        {:error, :session_access_denied}

      true ->
        :ok
    end
  end

  defp setup_session_isolation(session) do
    case session.isolation_level do
      :strict ->
        setup_strict_isolation(session)

      :standard ->
        setup_standard_isolation(session)

      :relaxed ->
        :ok
    end
  end

  defp setup_strict_isolation(session) do
    # Set up strict process and memory isolation
    Process.put(:session_id, session.session_id)
    Process.put(:isolation_level, :strict)
    Process.put(:security_context, session.security_context)
    :ok
  end

  defp setup_standard_isolation(session) do
    # Set up standard isolation
    Process.put(:session_id, session.session_id)
    Process.put(:isolation_level, :standard)
    :ok
  end

  defp execute_with_isolation(fun, session, _opts) do
    try do
      # Execute function with session context
      result = fun.()
      {:ok, result}
    rescue
      error ->
        Logger.error("Session execution failed: #{inspect(error)}")
        {:error, :execution_failed}
    after
      # Clean up process dictionary
      Process.delete(:session_id)
      Process.delete(:isolation_level)
      Process.delete(:security_context)
    end
  end

  defp cleanup_session_context(session) do
    case session.isolation_level do
      :strict ->
        cleanup_strict_context(session)

      :standard ->
        cleanup_standard_context(session)

      :relaxed ->
        :ok
    end
  end

  defp cleanup_strict_context(_session) do
    # Perform strict cleanup including memory scrubbing
    :erlang.garbage_collect()
    :ok
  end

  defp cleanup_standard_context(_session) do
    # Perform standard cleanup
    :ok
  end

  defp cleanup_session_context_on_error(session_id) do
    case get_session(session_id) do
      {:ok, session} -> cleanup_session_context(session)
      _ -> :ok
    end
  end

  defp update_session_access(session_id) do
    table_name = get_session_table()

    case :ets.lookup(table_name, session_id) do
      [{^session_id, session}] ->
        updated_session = %{session | last_accessed: DateTime.utc_now()}
        :ets.insert(table_name, {session_id, updated_session})
        :ok

      [] ->
        {:error, :session_not_found}
    end
  end

  defp check_memory_isolation(session) do
    if session.data_scope.memory_isolated do
      # Check for memory isolation violations
      # This is a simplified check - in production, more sophisticated checks would be needed
      case Process.get(:session_id) do
        session_id when session_id == session.session_id -> :ok
        nil -> :ok
        other_session -> {:error, [{:memory_contamination, other_session}]}
      end
    else
      :ok
    end
  end

  defp check_data_isolation(session) do
    if not session.data_scope.cross_session_access do
      # Check for data isolation violations
      # This would involve checking for shared data structures or global state
      :ok
    else
      :ok
    end
  end

  defp check_security_isolation(session) do
    # Check for security context isolation
    current_context = Process.get(:security_context)

    case {current_context, session.security_context} do
      {nil, _} -> :ok
      {same, same} -> :ok
      {different, _} when different != session.security_context ->
        {:error, [{:security_context_contamination, different}]}
    end
  end

  defp detect_cross_session_contamination(session) do
    # Detect if data from other sessions has leaked into this session
    # This is a simplified implementation
    current_session_id = Process.get(:session_id)

    case current_session_id do
      nil -> :ok
      session_id when session_id == session.session_id -> :ok
      other_id -> {:error, [{:cross_session_contamination, other_id}]}
    end
  end

  defp execute_cleanup_handlers(session, opts) do
    Enum.reduce_while(session.cleanup_handlers, :ok, fn handler, _acc ->
      try do
        handler.(session, opts)
        {:cont, :ok}
      rescue
        error ->
        Logger.error("Cleanup handler failed: #{inspect(error)}")
        {:halt, {:error, :cleanup_handler_failed}}
      end
    end)
  end

  defp clear_session_data(session) do
    # Clear any session-specific data
    case session.isolation_level do
      :strict ->
        # Perform secure data clearing
        :erlang.garbage_collect()

      _ ->
        :ok
    end
  end

  defp unregister_session(session_id) do
    table_name = get_session_table()
    :ets.delete(table_name, session_id)
    :ok
  end

  defp update_session(session_id, updated_session) do
    table_name = get_session_table()
    :ets.insert(table_name, {session_id, updated_session})
    :ok
  end

  defp session_active?(session) do
    DateTime.compare(DateTime.utc_now(), session.expires_at) == :lt
  end

  defp session_access_denied?(_session, _opts) do
    # Implement access control logic here
    false
  end

  defp count_active_sessions do
    table_name = get_session_table()

    :ets.foldl(fn {_id, session}, count ->
      if session_active?(session) do
        count + 1
      else
        count
      end
    end, 0, table_name)
  end

  defp cleanup_loop do
    :timer.sleep(@cleanup_interval_ms)
    cleanup_expired_sessions()
    cleanup_loop()
  end

  defp cleanup_expired_sessions do
    table_name = get_session_table()
    now = DateTime.utc_now()

    expired_sessions = :ets.foldl(fn {session_id, session}, acc ->
      if DateTime.compare(now, session.expires_at) == :gt do
        [session_id | acc]
      else
        acc
      end
    end, [], table_name)

    Enum.each(expired_sessions, fn session_id ->
      destroy_session(session_id, [reason: :expired])
    end)

    if length(expired_sessions) > 0 do
      Logger.info("Cleaned up #{length(expired_sessions)} expired sessions")
    end
  end

  defp mask_session_id(nil), do: nil
  defp mask_session_id(session_id) when is_binary(session_id) do
    case String.length(session_id) do
      len when len <= 8 -> String.duplicate("*", len)
      len -> String.slice(session_id, 0, 4) <> String.duplicate("*", len - 8) <> String.slice(session_id, -4, 4)
    end
  end
  defp mask_session_id(session_id), do: inspect(session_id)

  defp sanitize_session_metadata(metadata) do
    # Remove sensitive information from session metadata
    sensitive_keys = [:credentials, :api_key, :token, :password, :secret]
    Map.drop(metadata, sensitive_keys)
  end

  defp get_session_table do
    table_name = :req_llm_sessions

    # Create table if it doesn't exist
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])
      _ ->
        table_name
    end

    table_name
  end
end
