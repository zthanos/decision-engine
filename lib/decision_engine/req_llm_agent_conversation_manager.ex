defmodule DecisionEngine.ReqLLMAgentConversationManager do
  @moduledoc """
  Manages multi-turn conversations and isolation for agentic workflows.

  This module provides conversation management for agents, including multi-turn
  conversation support, agent conversation isolation, and concurrent agent
  conversation handling. Supports the agentic reflection pattern and other
  complex AI workflows that require stateful conversations.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger
  alias DecisionEngine.ReqLLMCorrelation
  alias DecisionEngine.ReqLLMSessionIsolator
  alias DecisionEngine.ReqLLMClient

  @type conversation_id :: String.t()
  @type agent_id :: String.t()
  @type message :: %{
    id: String.t(),
    role: :system | :user | :assistant,
    content: String.t(),
    timestamp: DateTime.t(),
    metadata: map()
  }

  @type conversation :: %{
    id: conversation_id(),
    agent_id: agent_id(),
    agent_type: atom(),
    messages: [message()],
    context: map(),
    status: :active | :paused | :completed | :error,
    isolation_context: map(),
    created_at: DateTime.t(),
    updated_at: DateTime.t(),
    metadata: map()
  }

  @type conversation_session :: %{
    conversation_id: conversation_id(),
    session_id: String.t(),
    agent_id: agent_id(),
    isolation_pid: pid() | nil,
    last_activity: DateTime.t(),
    resource_usage: map()
  }

  @doc """
  Creates a new conversation for an agent.

  ## Parameters
  - agent_id: Unique identifier for the agent
  - agent_type: Type of agent (:reflection, :refinement, :evaluation, etc.)
  - initial_context: Initial conversation context
  - options: Additional conversation options

  ## Returns
  - {:ok, conversation} on successful creation
  - {:error, reason} if creation fails
  """
  @spec create_conversation(agent_id(), atom(), map(), map()) :: {:ok, conversation()} | {:error, term()}
  def create_conversation(agent_id, agent_type, initial_context \\ %{}, options \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation_id} <- generate_conversation_id(),
         {:ok, isolation_context} <- ReqLLMSessionIsolator.create_isolation_context(agent_id, agent_type),
         {:ok, conversation} <- build_conversation(conversation_id, agent_id, agent_type, initial_context, isolation_context, options),
         :ok <- store_conversation(conversation),
         {:ok, session} <- create_conversation_session(conversation) do

      ReqLLMLogger.log_agent_event(:conversation_created, %{
        conversation_id: conversation_id,
        agent_id: agent_id,
        agent_type: agent_type
      }, %{correlation_id: correlation_id})

      {:ok, conversation}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:conversation_creation_failed, %{
          agent_id: agent_id,
          agent_type: agent_type,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Adds a message to an existing conversation.

  ## Parameters
  - conversation_id: ID of the conversation
  - role: Message role (:system, :user, :assistant)
  - content: Message content
  - metadata: Additional message metadata

  ## Returns
  - {:ok, updated_conversation} on success
  - {:error, reason} if adding message fails
  """
  @spec add_message(conversation_id(), atom(), String.t(), map()) :: {:ok, conversation()} | {:error, term()}
  def add_message(conversation_id, role, content, metadata \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation} <- get_conversation(conversation_id),
         :ok <- validate_conversation_active(conversation),
         {:ok, message} <- build_message(role, content, metadata),
         {:ok, updated_conversation} <- append_message_to_conversation(conversation, message),
         :ok <- store_conversation(updated_conversation),
         :ok <- update_session_activity(conversation_id) do

      ReqLLMLogger.log_agent_event(:message_added, %{
        conversation_id: conversation_id,
        role: role,
        content_length: String.length(content),
        total_messages: length(updated_conversation.messages)
      }, %{correlation_id: correlation_id})

      {:ok, updated_conversation}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:message_add_failed, %{
          conversation_id: conversation_id,
          role: role,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Sends a message in a conversation and gets LLM response.

  ## Parameters
  - conversation_id: ID of the conversation
  - user_message: User message content
  - llm_config: LLM configuration for the request
  - options: Additional options for the request

  ## Returns
  - {:ok, {updated_conversation, assistant_response}} on success
  - {:error, reason} if request fails
  """
  @spec send_message(conversation_id(), String.t(), map(), map()) :: {:ok, {conversation(), String.t()}} | {:error, term()}
  def send_message(conversation_id, user_message, llm_config, options \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation} <- get_conversation(conversation_id),
         :ok <- validate_conversation_active(conversation),
         {:ok, conversation_with_user_msg} <- add_message(conversation_id, :user, user_message),
         {:ok, conversation_context} <- build_conversation_context(conversation_with_user_msg),
         {:ok, llm_response} <- call_llm_with_isolation(conversation_with_user_msg, conversation_context, llm_config, options),
         {:ok, final_conversation} <- add_message(conversation_id, :assistant, llm_response) do

      ReqLLMLogger.log_agent_event(:message_sent, %{
        conversation_id: conversation_id,
        user_message_length: String.length(user_message),
        assistant_response_length: String.length(llm_response),
        total_messages: length(final_conversation.messages)
      }, %{correlation_id: correlation_id})

      {:ok, {final_conversation, llm_response}}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:message_send_failed, %{
          conversation_id: conversation_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Gets the current state of a conversation.

  ## Parameters
  - conversation_id: ID of the conversation

  ## Returns
  - {:ok, conversation} if found
  - {:error, reason} if not found or error
  """
  @spec get_conversation(conversation_id()) :: {:ok, conversation()} | {:error, term()}
  def get_conversation(conversation_id) do
    case lookup_conversation(conversation_id) do
      {:ok, conversation} ->
        {:ok, conversation}
      {:error, :not_found} ->
        {:error, "Conversation not found: #{conversation_id}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists conversations for a specific agent.

  ## Parameters
  - agent_id: ID of the agent
  - filters: Optional filters (status, agent_type, etc.)

  ## Returns
  - {:ok, conversations} list of conversations
  - {:error, reason} if listing fails
  """
  @spec list_conversations(agent_id(), map()) :: {:ok, [conversation()]} | {:error, term()}
  def list_conversations(agent_id, filters \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    try do
      conversations = get_all_conversations()

      filtered_conversations = conversations
      |> filter_by_agent_id(agent_id)
      |> apply_conversation_filters(filters)

      ReqLLMLogger.log_agent_event(:conversations_listed, %{
        agent_id: agent_id,
        total_conversations: length(conversations),
        filtered_conversations: length(filtered_conversations)
      }, %{correlation_id: correlation_id})

      {:ok, filtered_conversations}
    rescue
      error ->
        ReqLLMLogger.log_agent_event(:conversation_listing_failed, %{
          agent_id: agent_id,
          error: inspect(error)
        }, %{correlation_id: correlation_id})
        {:error, error}
    end
  end

  @doc """
  Pauses a conversation, preserving its state.

  ## Parameters
  - conversation_id: ID of the conversation

  ## Returns
  - {:ok, updated_conversation} on success
  - {:error, reason} if pausing fails
  """
  @spec pause_conversation(conversation_id()) :: {:ok, conversation()} | {:error, term()}
  def pause_conversation(conversation_id) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation} <- get_conversation(conversation_id),
         {:ok, updated_conversation} <- update_conversation_status(conversation, :paused),
         :ok <- store_conversation(updated_conversation),
         :ok <- cleanup_conversation_session(conversation_id) do

      ReqLLMLogger.log_agent_event(:conversation_paused, %{
        conversation_id: conversation_id,
        agent_id: conversation.agent_id
      }, %{correlation_id: correlation_id})

      {:ok, updated_conversation}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:conversation_pause_failed, %{
          conversation_id: conversation_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Resumes a paused conversation.

  ## Parameters
  - conversation_id: ID of the conversation

  ## Returns
  - {:ok, updated_conversation} on success
  - {:error, reason} if resuming fails
  """
  @spec resume_conversation(conversation_id()) :: {:ok, conversation()} | {:error, term()}
  def resume_conversation(conversation_id) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation} <- get_conversation(conversation_id),
         :ok <- validate_conversation_paused(conversation),
         {:ok, updated_conversation} <- update_conversation_status(conversation, :active),
         :ok <- store_conversation(updated_conversation),
         {:ok, _session} <- create_conversation_session(updated_conversation) do

      ReqLLMLogger.log_agent_event(:conversation_resumed, %{
        conversation_id: conversation_id,
        agent_id: conversation.agent_id
      }, %{correlation_id: correlation_id})

      {:ok, updated_conversation}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:conversation_resume_failed, %{
          conversation_id: conversation_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Completes a conversation, marking it as finished.

  ## Parameters
  - conversation_id: ID of the conversation
  - completion_metadata: Optional metadata about completion

  ## Returns
  - {:ok, updated_conversation} on success
  - {:error, reason} if completion fails
  """
  @spec complete_conversation(conversation_id(), map()) :: {:ok, conversation()} | {:error, term()}
  def complete_conversation(conversation_id, completion_metadata \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation} <- get_conversation(conversation_id),
         {:ok, updated_conversation} <- update_conversation_status(conversation, :completed, completion_metadata),
         :ok <- store_conversation(updated_conversation),
         :ok <- cleanup_conversation_session(conversation_id) do

      ReqLLMLogger.log_agent_event(:conversation_completed, %{
        conversation_id: conversation_id,
        agent_id: conversation.agent_id,
        total_messages: length(conversation.messages),
        duration_minutes: calculate_conversation_duration(conversation)
      }, %{correlation_id: correlation_id})

      {:ok, updated_conversation}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:conversation_completion_failed, %{
          conversation_id: conversation_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Gets active conversation sessions for monitoring.

  ## Returns
  - {:ok, sessions} list of active sessions
  - {:error, reason} if listing fails
  """
  @spec get_active_sessions() :: {:ok, [conversation_session()]} | {:error, term()}
  def get_active_sessions do
    try do
      sessions = get_all_sessions()
      active_sessions = Enum.filter(sessions, fn session ->
        # Consider session active if last activity was within 30 minutes
        time_diff = DateTime.diff(DateTime.utc_now(), session.last_activity, :minute)
        time_diff <= 30
      end)

      {:ok, active_sessions}
    rescue
      error ->
        {:error, error}
    end
  end

  # Private Functions

  defp generate_conversation_id do
    id = :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
    {:ok, "conv_" <> id}
  end

  defp build_conversation(conversation_id, agent_id, agent_type, initial_context, isolation_context, options) do
    now = DateTime.utc_now()

    conversation = %{
      id: conversation_id,
      agent_id: agent_id,
      agent_type: agent_type,
      messages: [],
      context: initial_context,
      status: :active,
      isolation_context: isolation_context,
      created_at: now,
      updated_at: now,
      metadata: Map.merge(%{
        max_messages: Map.get(options, :max_messages, 100),
        auto_cleanup: Map.get(options, :auto_cleanup, true),
        priority: Map.get(options, :priority, :normal)
      }, Map.get(options, :metadata, %{}))
    }

    {:ok, conversation}
  end

  defp build_message(role, content, metadata) do
    message = %{
      id: generate_message_id(),
      role: role,
      content: content,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }

    {:ok, message}
  end

  defp generate_message_id do
    :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)
  end

  defp store_conversation(conversation) do
    table_name = :req_llm_agent_conversations

    # Create table if it doesn't exist
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {conversation.id, conversation})
    :ok
  end

  defp lookup_conversation(conversation_id) do
    table_name = :req_llm_agent_conversations

    case :ets.lookup(table_name, conversation_id) do
      [{^conversation_id, conversation}] ->
        {:ok, conversation}
      [] ->
        {:error, :not_found}
    end
  end

  defp get_all_conversations do
    table_name = :req_llm_agent_conversations

    case :ets.whereis(table_name) do
      :undefined ->
        []
      _ ->
        :ets.tab2list(table_name)
        |> Enum.map(fn {_id, conversation} -> conversation end)
    end
  end

  defp validate_conversation_active(conversation) do
    case conversation.status do
      :active -> :ok
      status -> {:error, "Conversation is not active, current status: #{status}"}
    end
  end

  defp validate_conversation_paused(conversation) do
    case conversation.status do
      :paused -> :ok
      status -> {:error, "Conversation is not paused, current status: #{status}"}
    end
  end

  defp append_message_to_conversation(conversation, message) do
    # Check message limit
    max_messages = conversation.metadata.max_messages
    current_count = length(conversation.messages)

    if current_count >= max_messages do
      {:error, "Conversation has reached maximum message limit of #{max_messages}"}
    else
      updated_conversation = %{conversation |
        messages: conversation.messages ++ [message],
        updated_at: DateTime.utc_now()
      }
      {:ok, updated_conversation}
    end
  end

  defp build_conversation_context(conversation) do
    # Build context for LLM call including conversation history
    context = %{
      conversation_id: conversation.id,
      agent_id: conversation.agent_id,
      agent_type: conversation.agent_type,
      messages: conversation.messages,
      conversation_context: conversation.context,
      isolation_context: conversation.isolation_context
    }

    {:ok, context}
  end

  defp call_llm_with_isolation(conversation, conversation_context, llm_config, options) do
    # Use session isolation to ensure conversation isolation
    isolation_result = ReqLLMSessionIsolator.execute_with_isolation(
      conversation.isolation_context,
      fn ->
        # Build prompt from conversation history
        prompt = build_conversation_prompt(conversation.messages, options)

        # Call LLM with conversation context
        case ReqLLMClient.call_llm_with_priority(prompt, llm_config, :normal) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end
      end
    )

    case isolation_result do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_conversation_prompt(messages, options) do
    # Convert messages to a prompt format
    system_messages = Enum.filter(messages, fn msg -> msg.role == :system end)
    conversation_messages = Enum.filter(messages, fn msg -> msg.role != :system end)

    # Build system context
    system_context = case system_messages do
      [] -> "You are a helpful AI assistant."
      msgs -> Enum.map_join(msgs, "\n", fn msg -> msg.content end)
    end

    # Build conversation history
    conversation_history = Enum.map_join(conversation_messages, "\n", fn msg ->
      role_label = case msg.role do
        :user -> "Human"
        :assistant -> "Assistant"
        _ -> "System"
      end
      "#{role_label}: #{msg.content}"
    end)

    # Combine system context and conversation
    prompt = case Map.get(options, :include_system_context, true) do
      true -> "#{system_context}\n\n#{conversation_history}"
      false -> conversation_history
    end

    # Truncate if too long
    max_length = Map.get(options, :max_prompt_length, 4000)
    if String.length(prompt) > max_length do
      String.slice(prompt, -max_length, max_length)
    else
      prompt
    end
  end

  defp update_conversation_status(conversation, new_status, additional_metadata \\ %{}) do
    updated_conversation = %{conversation |
      status: new_status,
      updated_at: DateTime.utc_now(),
      metadata: Map.merge(conversation.metadata, additional_metadata)
    }

    {:ok, updated_conversation}
  end

  defp create_conversation_session(conversation) do
    session = %{
      conversation_id: conversation.id,
      session_id: generate_session_id(),
      agent_id: conversation.agent_id,
      isolation_pid: nil,  # Will be set by isolation manager if needed
      last_activity: DateTime.utc_now(),
      resource_usage: %{
        memory_mb: 0,
        cpu_percent: 0,
        message_count: length(conversation.messages)
      }
    }

    store_session(session)
    {:ok, session}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(12) |> Base.encode64(padding: false)
  end

  defp store_session(session) do
    table_name = :req_llm_agent_sessions

    # Create table if it doesn't exist
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {session.conversation_id, session})
    :ok
  end

  defp get_all_sessions do
    table_name = :req_llm_agent_sessions

    case :ets.whereis(table_name) do
      :undefined ->
        []
      _ ->
        :ets.tab2list(table_name)
        |> Enum.map(fn {_id, session} -> session end)
    end
  end

  defp update_session_activity(conversation_id) do
    case :ets.lookup(:req_llm_agent_sessions, conversation_id) do
      [{^conversation_id, session}] ->
        updated_session = %{session | last_activity: DateTime.utc_now()}
        :ets.insert(:req_llm_agent_sessions, {conversation_id, updated_session})
        :ok
      [] ->
        # Session doesn't exist, this is okay for completed conversations
        :ok
    end
  end

  defp cleanup_conversation_session(conversation_id) do
    :ets.delete(:req_llm_agent_sessions, conversation_id)
    :ok
  end

  defp filter_by_agent_id(conversations, agent_id) do
    Enum.filter(conversations, fn conversation ->
      conversation.agent_id == agent_id
    end)
  end

  defp apply_conversation_filters(conversations, filters) do
    Enum.reduce(filters, conversations, fn {filter_key, filter_value}, acc ->
      case filter_key do
        :status ->
          Enum.filter(acc, fn conversation ->
            conversation.status == filter_value
          end)

        :agent_type ->
          Enum.filter(acc, fn conversation ->
            conversation.agent_type == filter_value
          end)

        :created_after ->
          Enum.filter(acc, fn conversation ->
            DateTime.compare(conversation.created_at, filter_value) != :lt
          end)

        :has_messages ->
          Enum.filter(acc, fn conversation ->
            length(conversation.messages) > 0
          end)

        _ ->
          acc
      end
    end)
  end

  defp calculate_conversation_duration(conversation) do
    case conversation.messages do
      [] -> 0
      messages ->
        first_message = List.first(messages)
        last_message = List.last(messages)
        DateTime.diff(last_message.timestamp, first_message.timestamp, :minute)
    end
  end
end
