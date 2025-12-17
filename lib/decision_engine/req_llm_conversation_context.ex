defmodule DecisionEngine.ReqLLMConversationContext do
  @moduledoc """
  ReqLLM-based conversation context management for multi-turn conversations.

  This module provides conversation context management with ReqLLM integration,
  including conversation history tracking, context validation, and integrity checking.
  It supports the reflection pattern and other advanced AI workflows that require
  maintaining conversation state across multiple API calls.
  """

  use GenServer
  require Logger

  alias DecisionEngine.ReqLLMClient
  alias DecisionEngine.ReqLLMConfig

  @typedoc """
  Conversation message structure.
  """
  @type message :: %{
    role: :system | :user | :assistant,
    content: String.t(),
    timestamp: DateTime.t(),
    metadata: map()
  }

  @typedoc """
  Conversation context state.
  """
  @type context_state :: %{
    conversation_id: String.t(),
    messages: [message()],
    provider: atom(),
    model: String.t(),
    created_at: DateTime.t(),
    updated_at: DateTime.t(),
    metadata: map(),
    validation: %{
      integrity_hash: String.t(),
      message_count: integer(),
      total_tokens: integer()
    },
    limits: %{
      max_messages: integer(),
      max_tokens: integer(),
      max_age_hours: integer()
    }
  }

  # Configuration constants
  @default_max_messages 100
  @default_max_tokens 32000
  @default_max_age_hours 24
  @integrity_check_interval_ms 30_000

  ## Public API

  @doc """
  Starts a new conversation context manager.

  ## Parameters
  - conversation_id: Unique identifier for the conversation
  - opts: Optional configuration (provider, model, limits, etc.)

  ## Returns
  - {:ok, pid} on successful start
  - {:error, reason} if start fails
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(conversation_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {conversation_id, opts}, name: via_tuple(conversation_id))
  end

  @doc """
  Creates a new conversation context with ReqLLM configuration.

  ## Parameters
  - conversation_id: Unique identifier for the conversation
  - provider: LLM provider (:openai, :anthropic, etc.)
  - model: Model name
  - opts: Additional options (limits, metadata, etc.)

  ## Returns
  - {:ok, context_state} on success
  - {:error, reason} on failure
  """
  @spec create_conversation_context(String.t(), atom(), String.t(), keyword()) :: {:ok, context_state()} | {:error, term()}
  def create_conversation_context(conversation_id, provider, model, opts \\ []) do
    case start_link(conversation_id, [{:provider, provider}, {:model, model} | opts]) do
      {:ok, _pid} ->
        get_conversation_context(conversation_id)
      {:error, {:already_started, _pid}} ->
        get_conversation_context(conversation_id)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds a message to the conversation context.

  ## Parameters
  - conversation_id: The conversation to add the message to
  - role: Message role (:system, :user, :assistant)
  - content: Message content
  - metadata: Optional metadata map

  ## Returns
  - {:ok, updated_context} on success
  - {:error, reason} on failure
  """
  @spec add_message(String.t(), atom(), String.t(), map()) :: {:ok, context_state()} | {:error, term()}
  def add_message(conversation_id, role, content, metadata \\ %{}) do
    case GenServer.whereis(via_tuple(conversation_id)) do
      nil -> {:error, :conversation_not_found}
      pid -> GenServer.call(pid, {:add_message, role, content, metadata})
    end
  end

  @doc """
  Gets the current conversation context and history.

  ## Parameters
  - conversation_id: The conversation to retrieve

  ## Returns
  - {:ok, context_state} with current state
  - {:error, :not_found} if conversation doesn't exist
  """
  @spec get_conversation_context(String.t()) :: {:ok, context_state()} | {:error, :not_found}
  def get_conversation_context(conversation_id) do
    case GenServer.whereis(via_tuple(conversation_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_conversation_context)
    end
  end

  @doc """
  Gets the conversation history as a list of messages.

  ## Parameters
  - conversation_id: The conversation to retrieve history for

  ## Returns
  - {:ok, messages} list of messages
  - {:error, :not_found} if conversation doesn't exist
  """
  @spec get_conversation_history(String.t()) :: {:ok, [message()]} | {:error, :not_found}
  def get_conversation_history(conversation_id) do
    case get_conversation_context(conversation_id) do
      {:ok, context} -> {:ok, context.messages}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates conversation context integrity.

  ## Parameters
  - conversation_id: The conversation to validate

  ## Returns
  - :ok if validation passes
  - {:error, validation_errors} if validation fails
  """
  @spec validate_conversation_integrity(String.t()) :: :ok | {:error, [String.t()]}
  def validate_conversation_integrity(conversation_id) do
    case GenServer.whereis(via_tuple(conversation_id)) do
      nil -> {:error, [:conversation_not_found]}
      pid -> GenServer.call(pid, :validate_conversation_integrity)
    end
  end

  @doc """
  Updates conversation metadata.

  ## Parameters
  - conversation_id: The conversation to update
  - metadata: New metadata to merge

  ## Returns
  - {:ok, updated_context} on success
  - {:error, reason} on failure
  """
  @spec update_conversation_metadata(String.t(), map()) :: {:ok, context_state()} | {:error, term()}
  def update_conversation_metadata(conversation_id, metadata) do
    case GenServer.whereis(via_tuple(conversation_id)) do
      nil -> {:error, :conversation_not_found}
      pid -> GenServer.call(pid, {:update_metadata, metadata})
    end
  end

  @doc """
  Clears conversation history while preserving context structure.

  ## Parameters
  - conversation_id: The conversation to clear

  ## Returns
  - {:ok, cleared_context} on success
  - {:error, reason} on failure
  """
  @spec clear_conversation_history(String.t()) :: {:ok, context_state()} | {:error, term()}
  def clear_conversation_history(conversation_id) do
    case GenServer.whereis(via_tuple(conversation_id)) do
      nil -> {:error, :conversation_not_found}
      pid -> GenServer.call(pid, :clear_conversation_history)
    end
  end

  @doc """
  Lists all active conversation contexts.

  ## Returns
  - List of conversation IDs with basic info
  """
  @spec list_active_conversations() :: [map()]
  def list_active_conversations do
    Registry.select(DecisionEngine.ConversationRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.map(fn conversation_id ->
      case get_conversation_context(conversation_id) do
        {:ok, context} ->
          %{
            conversation_id: conversation_id,
            provider: context.provider,
            model: context.model,
            message_count: length(context.messages),
            created_at: context.created_at,
            updated_at: context.updated_at
          }
        {:error, _} -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  ## GenServer Callbacks

  @impl true
  def init({conversation_id, opts}) do
    # Set up periodic integrity checking
    Process.send_after(self(), :integrity_check, @integrity_check_interval_ms)

    # Initialize conversation context
    context = %{
      conversation_id: conversation_id,
      messages: [],
      provider: Keyword.get(opts, :provider, :openai),
      model: Keyword.get(opts, :model, "gpt-4"),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{}),
      validation: %{
        integrity_hash: calculate_integrity_hash([]),
        message_count: 0,
        total_tokens: 0
      },
      limits: %{
        max_messages: Keyword.get(opts, :max_messages, @default_max_messages),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        max_age_hours: Keyword.get(opts, :max_age_hours, @default_max_age_hours)
      }
    }

    Logger.info("ReqLLM conversation context created for #{conversation_id}")

    {:ok, context}
  end

  @impl true
  def handle_call({:add_message, role, content, metadata}, _from, context) do
    # Validate message before adding
    case validate_message(role, content, context) do
      :ok ->
        message = %{
          role: role,
          content: content,
          timestamp: DateTime.utc_now(),
          metadata: metadata
        }

        updated_messages = context.messages ++ [message]

        # Check limits
        case check_conversation_limits(updated_messages, context.limits) do
          :ok ->
            # Update context with new message
            updated_context = %{context |
              messages: updated_messages,
              updated_at: DateTime.utc_now(),
              validation: %{context.validation |
                integrity_hash: calculate_integrity_hash(updated_messages),
                message_count: length(updated_messages),
                total_tokens: estimate_total_tokens(updated_messages)
              }
            }

            Logger.debug("Message added to conversation #{context.conversation_id}: #{role}")

            {:reply, {:ok, updated_context}, updated_context}

          {:error, limit_error} ->
            Logger.warning("Message rejected due to limits for conversation #{context.conversation_id}: #{inspect(limit_error)}")
            {:reply, {:error, limit_error}, context}
        end

      {:error, validation_error} ->
        Logger.warning("Invalid message for conversation #{context.conversation_id}: #{inspect(validation_error)}")
        {:reply, {:error, validation_error}, context}
    end
  end

  @impl true
  def handle_call(:get_conversation_context, _from, context) do
    {:reply, {:ok, context}, context}
  end

  @impl true
  def handle_call(:validate_conversation_integrity, _from, context) do
    validation_result = perform_integrity_validation(context)
    {:reply, validation_result, context}
  end

  @impl true
  def handle_call({:update_metadata, new_metadata}, _from, context) do
    updated_context = %{context |
      metadata: Map.merge(context.metadata, new_metadata),
      updated_at: DateTime.utc_now()
    }

    {:reply, {:ok, updated_context}, updated_context}
  end

  @impl true
  def handle_call(:clear_conversation_history, _from, context) do
    cleared_context = %{context |
      messages: [],
      updated_at: DateTime.utc_now(),
      validation: %{context.validation |
        integrity_hash: calculate_integrity_hash([]),
        message_count: 0,
        total_tokens: 0
      }
    }

    Logger.info("Conversation history cleared for #{context.conversation_id}")

    {:reply, {:ok, cleared_context}, cleared_context}
  end

  @impl true
  def handle_info(:integrity_check, context) do
    # Perform periodic integrity validation
    case perform_integrity_validation(context) do
      :ok ->
        Logger.debug("Integrity check passed for conversation #{context.conversation_id}")

      {:error, errors} ->
        Logger.warning("Integrity check failed for conversation #{context.conversation_id}: #{inspect(errors)}")

        # Attempt to repair context if possible
        repaired_context = attempt_context_repair(context, errors)

        # Schedule next integrity check
        Process.send_after(self(), :integrity_check, @integrity_check_interval_ms)

        {:noreply, repaired_context}
    end

    # Schedule next integrity check
    Process.send_after(self(), :integrity_check, @integrity_check_interval_ms)

    {:noreply, context}
  end

  ## Private Functions

  # Validate message content and role
  defp validate_message(role, content, context) do
    cond do
      role not in [:system, :user, :assistant] ->
        {:error, :invalid_role}

      not is_binary(content) or String.trim(content) == "" ->
        {:error, :empty_content}

      String.length(content) > 50_000 ->
        {:error, :content_too_long}

      # Check if adding this message would exceed token limits
      true ->
        estimated_tokens = estimate_message_tokens(content)
        if context.validation.total_tokens + estimated_tokens > context.limits.max_tokens do
          {:error, :token_limit_exceeded}
        else
          :ok
        end
    end
  end

  # Check conversation limits
  defp check_conversation_limits(messages, limits) do
    cond do
      length(messages) > limits.max_messages ->
        {:error, :message_limit_exceeded}

      estimate_total_tokens(messages) > limits.max_tokens ->
        {:error, :token_limit_exceeded}

      true ->
        :ok
    end
  end

  # Calculate integrity hash for messages
  defp calculate_integrity_hash(messages) do
    messages
    |> Enum.map(fn msg -> "#{msg.role}:#{msg.content}:#{DateTime.to_iso8601(msg.timestamp)}" end)
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  # Estimate tokens for a message (rough approximation)
  defp estimate_message_tokens(content) do
    # Rough approximation: 1 token per 4 characters
    div(String.length(content), 4) + 10  # Add overhead for role and formatting
  end

  # Estimate total tokens for all messages
  defp estimate_total_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_message_tokens(msg.content)
    end)
  end

  # Perform comprehensive integrity validation
  defp perform_integrity_validation(context) do
    errors = []

    # Check message count consistency
    errors = if length(context.messages) != context.validation.message_count do
      ["Message count mismatch: expected #{context.validation.message_count}, got #{length(context.messages)}" | errors]
    else
      errors
    end

    # Check integrity hash
    expected_hash = calculate_integrity_hash(context.messages)
    errors = if expected_hash != context.validation.integrity_hash do
      ["Integrity hash mismatch: expected #{expected_hash}, got #{context.validation.integrity_hash}" | errors]
    else
      errors
    end

    # Check token count consistency
    actual_tokens = estimate_total_tokens(context.messages)
    errors = if abs(actual_tokens - context.validation.total_tokens) > 100 do  # Allow some variance
      ["Token count mismatch: expected ~#{context.validation.total_tokens}, got #{actual_tokens}" | errors]
    else
      errors
    end

    # Check message structure integrity
    errors = Enum.reduce(context.messages, errors, fn msg, acc ->
      case validate_message_structure(msg) do
        :ok -> acc
        {:error, error} -> ["Invalid message structure: #{error}" | acc]
      end
    end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # Validate individual message structure
  defp validate_message_structure(message) do
    required_fields = [:role, :content, :timestamp, :metadata]

    cond do
      not is_map(message) ->
        {:error, "Message is not a map"}

      not Enum.all?(required_fields, &Map.has_key?(message, &1)) ->
        missing = required_fields -- Map.keys(message)
        {:error, "Missing required fields: #{inspect(missing)}"}

      message.role not in [:system, :user, :assistant] ->
        {:error, "Invalid role: #{inspect(message.role)}"}

      not is_binary(message.content) ->
        {:error, "Content is not a string"}

      not is_struct(message.timestamp, DateTime) ->
        {:error, "Timestamp is not a DateTime"}

      not is_map(message.metadata) ->
        {:error, "Metadata is not a map"}

      true ->
        :ok
    end
  end

  # Attempt to repair context integrity issues
  defp attempt_context_repair(context, errors) do
    Logger.info("Attempting to repair conversation context for #{context.conversation_id}")

    # Recalculate validation fields based on current messages
    repaired_validation = %{
      integrity_hash: calculate_integrity_hash(context.messages),
      message_count: length(context.messages),
      total_tokens: estimate_total_tokens(context.messages)
    }

    repaired_context = %{context |
      validation: repaired_validation,
      updated_at: DateTime.utc_now()
    }

    Logger.info("Context repair completed for #{context.conversation_id}")

    repaired_context
  end

  # Registry via tuple for conversation management
  defp via_tuple(conversation_id) do
    {:via, Registry, {DecisionEngine.ConversationRegistry, conversation_id}}
  end
end
