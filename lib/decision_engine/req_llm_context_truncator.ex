defmodule DecisionEngine.ReqLLMContextTruncator do
  @moduledoc """
  Intelligent context truncation and summarization strategies for ReqLLM conversations.

  This module provides context size management, summarization for large conversations,
  and context prioritization and retention policies. It ensures conversations stay
  within token limits while preserving important context for multi-turn interactions.
  """

  require Logger

  alias DecisionEngine.ReqLLMClient
  alias DecisionEngine.ReqLLMConversationContext

  @typedoc """
  Truncation strategy configuration.
  """
  @type truncation_strategy :: %{
    strategy: :sliding_window | :summarization | :priority_based | :hybrid,
    max_tokens: integer(),
    preserve_system: boolean(),
    preserve_recent: integer(),
    summarization_ratio: float(),
    priority_weights: map()
  }

  @typedoc """
  Truncation result.
  """
  @type truncation_result :: %{
    original_messages: [map()],
    truncated_messages: [map()],
    summary: String.t() | nil,
    tokens_saved: integer(),
    strategy_used: atom(),
    metadata: map()
  }

  # Default configuration
  @default_max_tokens 8000
  @default_preserve_recent 5
  @default_summarization_ratio 0.3
  @sliding_window_overlap 2

  ## Public API

  @doc """
  Applies intelligent context truncation to a conversation.

  ## Parameters
  - conversation_id: The conversation to truncate
  - strategy_config: Truncation strategy configuration
  - target_tokens: Target token count (optional, uses strategy config if nil)

  ## Returns
  - {:ok, truncation_result} on success
  - {:error, reason} on failure
  """
  @spec truncate_conversation_context(String.t(), truncation_strategy(), integer() | nil) ::
    {:ok, truncation_result()} | {:error, term()}
  def truncate_conversation_context(conversation_id, strategy_config, target_tokens \\ nil) do
    case ReqLLMConversationContext.get_conversation_context(conversation_id) do
      {:ok, context} ->
        target = target_tokens || strategy_config.max_tokens

        case apply_truncation_strategy(context.messages, strategy_config, target, context) do
          {:ok, result} ->
            # Update conversation with truncated messages
            case update_conversation_with_truncated_messages(conversation_id, result) do
              {:ok, _updated_context} ->
                Logger.info("Context truncated for conversation #{conversation_id}: #{result.tokens_saved} tokens saved")
                {:ok, result}

              {:error, reason} ->
                Logger.error("Failed to update conversation with truncated messages: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a summary of conversation messages using LLM.

  ## Parameters
  - messages: List of messages to summarize
  - provider: LLM provider to use for summarization
  - model: Model to use for summarization
  - opts: Additional options (max_summary_tokens, etc.)

  ## Returns
  - {:ok, summary_text} on success
  - {:error, reason} on failure
  """
  @spec create_conversation_summary([map()], atom(), String.t(), keyword()) ::
    {:ok, String.t()} | {:error, term()}
  def create_conversation_summary(messages, provider, model, opts \\ []) do
    max_summary_tokens = Keyword.get(opts, :max_summary_tokens, 500)

    # Build summarization prompt
    conversation_text = format_messages_for_summarization(messages)

    summarization_prompt = """
    Please provide a concise summary of the following conversation that preserves the key context and decisions made.
    Focus on:
    1. Main topics discussed
    2. Key decisions or conclusions reached
    3. Important context that would be needed for future conversation
    4. Any unresolved issues or questions

    Keep the summary under #{max_summary_tokens} tokens while maintaining essential context.

    Conversation:
    #{conversation_text}

    Summary:
    """

    # Create ReqLLM config for summarization
    config = %{
      provider: provider,
      model: model,
      base_url: get_provider_base_url(provider),
      api_key: get_provider_api_key(provider),
      max_tokens: max_summary_tokens,
      temperature: 0.3  # Lower temperature for more consistent summaries
    }

    case ReqLLMClient.call_llm(summarization_prompt, config) do
      {:ok, summary} ->
        cleaned_summary = String.trim(summary)
        Logger.debug("Created conversation summary: #{String.length(cleaned_summary)} characters")
        {:ok, cleaned_summary}

      {:error, reason} ->
        Logger.error("Failed to create conversation summary: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Calculates priority scores for messages based on various factors.

  ## Parameters
  - messages: List of messages to score
  - priority_weights: Weight configuration for different factors

  ## Returns
  - List of {message, priority_score} tuples sorted by priority (highest first)
  """
  @spec calculate_message_priorities([map()], map()) :: [{map(), float()}]
  def calculate_message_priorities(messages, priority_weights \\ %{}) do
    weights = Map.merge(default_priority_weights(), priority_weights)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      score = calculate_message_priority_score(message, index, length(messages), weights)
      {message, score}
    end)
    |> Enum.sort_by(fn {_message, score} -> score end, :desc)
  end

  @doc """
  Estimates token count for a list of messages.

  ## Parameters
  - messages: List of messages to count tokens for

  ## Returns
  - Estimated token count
  """
  @spec estimate_messages_token_count([map()]) :: integer()
  def estimate_messages_token_count(messages) do
    Enum.reduce(messages, 0, fn message, acc ->
      acc + estimate_message_tokens(message.content) + 10  # Add overhead for role and formatting
    end)
  end

  @doc """
  Gets the default truncation strategy configuration.

  ## Returns
  - Default truncation strategy map
  """
  @spec get_default_truncation_strategy() :: truncation_strategy()
  def get_default_truncation_strategy do
    %{
      strategy: :hybrid,
      max_tokens: @default_max_tokens,
      preserve_system: true,
      preserve_recent: @default_preserve_recent,
      summarization_ratio: @default_summarization_ratio,
      priority_weights: default_priority_weights()
    }
  end

  ## Private Functions

  # Apply the selected truncation strategy
  defp apply_truncation_strategy(messages, strategy_config, target_tokens, context) do
    current_tokens = estimate_messages_token_count(messages)

    if current_tokens <= target_tokens do
      # No truncation needed
      {:ok, %{
        original_messages: messages,
        truncated_messages: messages,
        summary: nil,
        tokens_saved: 0,
        strategy_used: :none,
        metadata: %{current_tokens: current_tokens, target_tokens: target_tokens}
      }}
    else
      case strategy_config.strategy do
        :sliding_window ->
          apply_sliding_window_truncation(messages, strategy_config, target_tokens)

        :summarization ->
          apply_summarization_truncation(messages, strategy_config, target_tokens, context)

        :priority_based ->
          apply_priority_based_truncation(messages, strategy_config, target_tokens)

        :hybrid ->
          apply_hybrid_truncation(messages, strategy_config, target_tokens, context)

        _ ->
          {:error, "Unknown truncation strategy: #{strategy_config.strategy}"}
      end
    end
  end

  # Sliding window truncation - keep recent messages and system messages
  defp apply_sliding_window_truncation(messages, strategy_config, target_tokens) do
    {system_messages, other_messages} = Enum.split_with(messages, &(&1.role == :system))

    # Always preserve system messages if configured
    preserved_messages = if strategy_config.preserve_system, do: system_messages, else: []

    # Calculate tokens used by preserved messages
    preserved_tokens = estimate_messages_token_count(preserved_messages)
    remaining_tokens = target_tokens - preserved_tokens

    if remaining_tokens <= 0 do
      {:error, "System messages exceed target token limit"}
    else
      # Keep recent messages within remaining token budget
      recent_messages = take_recent_messages_within_budget(other_messages, remaining_tokens, strategy_config.preserve_recent)

      truncated_messages = preserved_messages ++ recent_messages
      original_tokens = estimate_messages_token_count(messages)
      final_tokens = estimate_messages_token_count(truncated_messages)

      {:ok, %{
        original_messages: messages,
        truncated_messages: truncated_messages,
        summary: nil,
        tokens_saved: original_tokens - final_tokens,
        strategy_used: :sliding_window,
        metadata: %{
          original_tokens: original_tokens,
          final_tokens: final_tokens,
          preserved_system_count: length(system_messages),
          preserved_recent_count: length(recent_messages)
        }
      }}
    end
  end

  # Summarization truncation - summarize old messages, keep recent ones
  defp apply_summarization_truncation(messages, strategy_config, target_tokens, context) do
    {system_messages, other_messages} = Enum.split_with(messages, &(&1.role == :system))

    # Calculate how many recent messages to preserve
    recent_count = strategy_config.preserve_recent
    {messages_to_summarize, recent_messages} =
      if length(other_messages) > recent_count do
        Enum.split(other_messages, length(other_messages) - recent_count)
      else
        {[], other_messages}
      end

    if length(messages_to_summarize) == 0 do
      # Nothing to summarize, fall back to sliding window
      apply_sliding_window_truncation(messages, strategy_config, target_tokens)
    else
      # Create summary of older messages
      case create_conversation_summary(messages_to_summarize, context.provider, context.model) do
        {:ok, summary} ->
          # Create summary message
          summary_message = %{
            role: :system,
            content: "Previous conversation summary: #{summary}",
            timestamp: DateTime.utc_now(),
            metadata: %{generated_summary: true, summarized_count: length(messages_to_summarize)}
          }

          # Combine preserved messages
          preserved_messages = if strategy_config.preserve_system, do: system_messages, else: []
          truncated_messages = preserved_messages ++ [summary_message] ++ recent_messages

          # Check if we're within token budget
          final_tokens = estimate_messages_token_count(truncated_messages)

          if final_tokens <= target_tokens do
            original_tokens = estimate_messages_token_count(messages)

            {:ok, %{
              original_messages: messages,
              truncated_messages: truncated_messages,
              summary: summary,
              tokens_saved: original_tokens - final_tokens,
              strategy_used: :summarization,
              metadata: %{
                original_tokens: original_tokens,
                final_tokens: final_tokens,
                summarized_count: length(messages_to_summarize),
                summary_length: String.length(summary)
              }
            }}
          else
            # Still too many tokens, apply additional truncation
            apply_sliding_window_truncation(truncated_messages, strategy_config, target_tokens)
          end

        {:error, reason} ->
          Logger.warning("Summarization failed, falling back to sliding window: #{inspect(reason)}")
          apply_sliding_window_truncation(messages, strategy_config, target_tokens)
      end
    end
  end

  # Priority-based truncation - keep highest priority messages
  defp apply_priority_based_truncation(messages, strategy_config, target_tokens) do
    # Calculate priorities for all messages
    prioritized_messages = calculate_message_priorities(messages, strategy_config.priority_weights)

    # Always preserve system messages if configured
    {system_messages, other_prioritized} =
      Enum.split_with(prioritized_messages, fn {msg, _score} -> msg.role == :system end)

    preserved_system = if strategy_config.preserve_system do
      Enum.map(system_messages, fn {msg, _score} -> msg end)
    else
      []
    end

    # Calculate remaining token budget
    preserved_tokens = estimate_messages_token_count(preserved_system)
    remaining_tokens = target_tokens - preserved_tokens

    if remaining_tokens <= 0 do
      {:error, "System messages exceed target token limit"}
    else
      # Select highest priority messages within budget
      selected_messages = select_messages_by_priority_within_budget(other_prioritized, remaining_tokens)

      # Combine and sort by original order
      all_selected = preserved_system ++ selected_messages
      truncated_messages = sort_messages_by_timestamp(all_selected)

      original_tokens = estimate_messages_token_count(messages)
      final_tokens = estimate_messages_token_count(truncated_messages)

      {:ok, %{
        original_messages: messages,
        truncated_messages: truncated_messages,
        summary: nil,
        tokens_saved: original_tokens - final_tokens,
        strategy_used: :priority_based,
        metadata: %{
          original_tokens: original_tokens,
          final_tokens: final_tokens,
          selected_count: length(selected_messages),
          priority_threshold: get_lowest_selected_priority(other_prioritized, selected_messages)
        }
      }}
    end
  end

  # Hybrid truncation - combine multiple strategies intelligently
  defp apply_hybrid_truncation(messages, strategy_config, target_tokens, context) do
    current_tokens = estimate_messages_token_count(messages)
    tokens_to_save = current_tokens - target_tokens

    cond do
      # If we need to save less than 30% of tokens, use sliding window
      tokens_to_save / current_tokens < 0.3 ->
        apply_sliding_window_truncation(messages, strategy_config, target_tokens)

      # If we need to save 30-60% of tokens, try summarization first
      tokens_to_save / current_tokens < 0.6 ->
        case apply_summarization_truncation(messages, strategy_config, target_tokens, context) do
          {:ok, result} -> {:ok, %{result | strategy_used: :hybrid_summarization}}
          {:error, _} -> apply_priority_based_truncation(messages, strategy_config, target_tokens)
        end

      # If we need to save more than 60% of tokens, use priority-based
      true ->
        case apply_priority_based_truncation(messages, strategy_config, target_tokens) do
          {:ok, result} -> {:ok, %{result | strategy_used: :hybrid_priority}}
          {:error, _} -> apply_sliding_window_truncation(messages, strategy_config, target_tokens)
        end
    end
  end

  # Take recent messages within token budget
  defp take_recent_messages_within_budget(messages, token_budget, min_preserve) do
    reversed_messages = Enum.reverse(messages)

    {selected, _remaining_budget} =
      Enum.reduce_while(reversed_messages, {[], token_budget}, fn message, {acc, budget} ->
        message_tokens = estimate_message_tokens(message.content) + 10

        if message_tokens <= budget or length(acc) < min_preserve do
          {:cont, {[message | acc], budget - message_tokens}}
        else
          {:halt, {acc, budget}}
        end
      end)

    Enum.reverse(selected)
  end

  # Select messages by priority within token budget
  defp select_messages_by_priority_within_budget(prioritized_messages, token_budget) do
    {selected, _remaining_budget} =
      Enum.reduce_while(prioritized_messages, {[], token_budget}, fn {message, _priority}, {acc, budget} ->
        message_tokens = estimate_message_tokens(message.content) + 10

        if message_tokens <= budget do
          {:cont, {[message | acc], budget - message_tokens}}
        else
          {:halt, {acc, budget}}
        end
      end)

    Enum.reverse(selected)
  end

  # Sort messages by timestamp to maintain conversation order
  defp sort_messages_by_timestamp(messages) do
    Enum.sort_by(messages, & &1.timestamp, DateTime)
  end

  # Get the lowest priority score among selected messages
  defp get_lowest_selected_priority(prioritized_messages, selected_messages) do
    selected_set = MapSet.new(selected_messages)

    prioritized_messages
    |> Enum.filter(fn {msg, _priority} -> MapSet.member?(selected_set, msg) end)
    |> Enum.map(fn {_msg, priority} -> priority end)
    |> Enum.min(fn -> 0.0 end)
  end

  # Calculate priority score for a single message
  defp calculate_message_priority_score(message, index, total_messages, weights) do
    # Base factors for priority calculation
    recency_score = (total_messages - index) / total_messages  # More recent = higher score
    role_score = get_role_priority_score(message.role)
    length_score = min(String.length(message.content) / 1000, 1.0)  # Longer messages get slight boost, capped at 1.0

    # Check for special content indicators
    content_score = calculate_content_priority_score(message.content)

    # Weighted combination
    weights.recency * recency_score +
    weights.role * role_score +
    weights.length * length_score +
    weights.content * content_score
  end

  # Get priority score based on message role
  defp get_role_priority_score(role) do
    case role do
      :system -> 1.0      # System messages are highest priority
      :assistant -> 0.8   # Assistant responses are important
      :user -> 0.6        # User messages are moderately important
      _ -> 0.5
    end
  end

  # Calculate content-based priority score
  defp calculate_content_priority_score(content) do
    content_lower = String.downcase(content)

    # Look for important keywords/patterns
    importance_indicators = [
      {"decision", 0.3},
      {"conclusion", 0.3},
      {"summary", 0.2},
      {"important", 0.2},
      {"error", 0.2},
      {"warning", 0.2},
      {"action", 0.1},
      {"next steps", 0.2},
      {"todo", 0.1}
    ]

    Enum.reduce(importance_indicators, 0.0, fn {keyword, weight}, acc ->
      if String.contains?(content_lower, keyword) do
        acc + weight
      else
        acc
      end
    end)
    |> min(1.0)  # Cap at 1.0
  end

  # Default priority weights
  defp default_priority_weights do
    %{
      recency: 0.4,    # Recent messages are important
      role: 0.3,       # Message role matters
      length: 0.1,     # Longer messages get slight boost
      content: 0.2     # Content-based importance
    }
  end

  # Format messages for summarization prompt
  defp format_messages_for_summarization(messages) do
    messages
    |> Enum.map(fn message ->
      timestamp = DateTime.to_string(message.timestamp)
      "#{String.upcase(to_string(message.role))} [#{timestamp}]: #{message.content}"
    end)
    |> Enum.join("\n\n")
  end

  # Estimate tokens for message content
  defp estimate_message_tokens(content) do
    # Rough approximation: 1 token per 4 characters
    div(String.length(content), 4)
  end

  # Update conversation with truncated messages
  defp update_conversation_with_truncated_messages(conversation_id, truncation_result) do
    # Clear existing messages and add truncated ones
    case ReqLLMConversationContext.clear_conversation_history(conversation_id) do
      {:ok, _cleared_context} ->
        # Add truncated messages back
        add_messages_to_conversation(conversation_id, truncation_result.truncated_messages)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Add multiple messages to conversation
  defp add_messages_to_conversation(conversation_id, messages) do
    Enum.reduce_while(messages, {:ok, nil}, fn message, _acc ->
      case ReqLLMConversationContext.add_message(
        conversation_id,
        message.role,
        message.content,
        message.metadata
      ) do
        {:ok, context} -> {:cont, {:ok, context}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Get provider base URL (placeholder - should be configured properly)
  defp get_provider_base_url(provider) do
    case provider do
      :openai -> "https://api.openai.com/v1/chat/completions"
      :anthropic -> "https://api.anthropic.com/v1/messages"
      :ollama -> "http://localhost:11434/api/chat"
      _ -> "https://api.openai.com/v1/chat/completions"
    end
  end

  # Get provider API key (placeholder - should be configured properly)
  defp get_provider_api_key(provider) do
    case provider do
      :openai -> System.get_env("OPENAI_API_KEY")
      :anthropic -> System.get_env("ANTHROPIC_API_KEY")
      :ollama -> nil
      _ -> System.get_env("OPENAI_API_KEY")
    end
  end
end
