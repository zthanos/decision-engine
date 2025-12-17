defmodule DecisionEngine.ReqLLMConversationBrancher do
  @moduledoc """
  Conversation branching and forking support for ReqLLM conversations.

  This module implements conversation branching and forking capabilities,
  context isolation between conversation branches, and branch merging
  and conflict resolution. It supports reflection processes that require
  iterative improvements and parallel conversation paths.
  """

  use GenServer
  require Logger

  alias DecisionEngine.ReqLLMConversationContext
  alias DecisionEngine.ReqLLMContextTruncator

  @typedoc """
  Branch information structure.
  """
  @type branch_info :: %{
    branch_id: String.t(),
    parent_conversation_id: String.t(),
    branch_point_index: integer(),
    created_at: DateTime.t(),
    metadata: map(),
    status: :active | :merged | :abandoned
  }

  @typedoc """
  Branch tree structure.
  """
  @type branch_tree :: %{
    root_conversation_id: String.t(),
    branches: %{String.t() => branch_info()},
    branch_hierarchy: map(),
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @typedoc """
  Merge strategy configuration.
  """
  @type merge_strategy :: %{
    strategy: :append | :interleave | :priority_based | :manual,
    conflict_resolution: :keep_source | :keep_target | :merge_both | :manual,
    preserve_timestamps: boolean(),
    merge_metadata: boolean()
  }

  # Configuration constants
  @max_branch_depth 10
  @branch_cleanup_interval_ms 300_000  # 5 minutes

  ## Public API

  @doc """
  Starts a conversation brancher for managing conversation branches.

  ## Parameters
  - root_conversation_id: The root conversation to manage branches for
  - opts: Optional configuration

  ## Returns
  - {:ok, pid} on successful start
  - {:error, reason} if start fails
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(root_conversation_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {root_conversation_id, opts},
      name: via_tuple(root_conversation_id))
  end

  @doc """
  Creates a new branch from a conversation at a specific message index.

  ## Parameters
  - root_conversation_id: The root conversation to branch from
  - branch_point_index: Index of the message to branch from
  - branch_metadata: Optional metadata for the branch

  ## Returns
  - {:ok, branch_id} on success
  - {:error, reason} on failure
  """
  @spec create_conversation_branch(String.t(), integer(), map()) ::
    {:ok, String.t()} | {:error, term()}
  def create_conversation_branch(root_conversation_id, branch_point_index, branch_metadata \\ %{}) do
    case GenServer.whereis(via_tuple(root_conversation_id)) do
      nil ->
        # Start brancher if it doesn't exist
        case start_link(root_conversation_id) do
          {:ok, pid} ->
            GenServer.call(pid, {:create_branch, branch_point_index, branch_metadata})
          {:error, reason} ->
            {:error, reason}
        end

      pid ->
        GenServer.call(pid, {:create_branch, branch_point_index, branch_metadata})
    end
  end

  @doc """
  Forks a conversation by creating a complete copy with isolation.

  ## Parameters
  - source_conversation_id: The conversation to fork
  - fork_metadata: Optional metadata for the fork

  ## Returns
  - {:ok, fork_conversation_id} on success
  - {:error, reason} on failure
  """
  @spec fork_conversation(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def fork_conversation(source_conversation_id, fork_metadata \\ %{}) do
    case ReqLLMConversationContext.get_conversation_context(source_conversation_id) do
      {:ok, source_context} ->
        fork_id = generate_conversation_id("fork")

        # Create new conversation with same configuration
        case ReqLLMConversationContext.create_conversation_context(
          fork_id,
          source_context.provider,
          source_context.model,
          [
            metadata: Map.merge(source_context.metadata, fork_metadata),
            max_messages: source_context.limits.max_messages,
            max_tokens: source_context.limits.max_tokens,
            max_age_hours: source_context.limits.max_age_hours
          ]
        ) do
          {:ok, _fork_context} ->
            # Copy all messages to the fork
            case copy_messages_to_conversation(source_context.messages, fork_id) do
              {:ok, _} ->
                Logger.info("Conversation forked: #{source_conversation_id} -> #{fork_id}")
                {:ok, fork_id}

              {:error, reason} ->
                Logger.error("Failed to copy messages to fork: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create fork conversation: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges a branch back into its parent conversation.

  ## Parameters
  - root_conversation_id: The root conversation managing branches
  - branch_id: The branch to merge
  - merge_strategy: Strategy for merging (optional, uses default if nil)

  ## Returns
  - {:ok, merge_result} on success
  - {:error, reason} on failure
  """
  @spec merge_conversation_branch(String.t(), String.t(), merge_strategy() | nil) ::
    {:ok, map()} | {:error, term()}
  def merge_conversation_branch(root_conversation_id, branch_id, merge_strategy \\ nil) do
    case GenServer.whereis(via_tuple(root_conversation_id)) do
      nil -> {:error, :brancher_not_found}
      pid -> GenServer.call(pid, {:merge_branch, branch_id, merge_strategy})
    end
  end

  @doc """
  Gets the branch tree structure for a root conversation.

  ## Parameters
  - root_conversation_id: The root conversation to get branches for

  ## Returns
  - {:ok, branch_tree} on success
  - {:error, reason} on failure
  """
  @spec get_branch_tree(String.t()) :: {:ok, branch_tree()} | {:error, term()}
  def get_branch_tree(root_conversation_id) do
    case GenServer.whereis(via_tuple(root_conversation_id)) do
      nil -> {:error, :brancher_not_found}
      pid -> GenServer.call(pid, :get_branch_tree)
    end
  end

  @doc """
  Lists all active branches for a root conversation.

  ## Parameters
  - root_conversation_id: The root conversation to list branches for

  ## Returns
  - {:ok, [branch_info]} on success
  - {:error, reason} on failure
  """
  @spec list_conversation_branches(String.t()) :: {:ok, [branch_info()]} | {:error, term()}
  def list_conversation_branches(root_conversation_id) do
    case get_branch_tree(root_conversation_id) do
      {:ok, branch_tree} ->
        active_branches =
          branch_tree.branches
          |> Enum.filter(fn {_id, info} -> info.status == :active end)
          |> Enum.map(fn {_id, info} -> info end)

        {:ok, active_branches}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Abandons a branch, marking it as inactive without merging.

  ## Parameters
  - root_conversation_id: The root conversation managing branches
  - branch_id: The branch to abandon

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec abandon_conversation_branch(String.t(), String.t()) :: :ok | {:error, term()}
  def abandon_conversation_branch(root_conversation_id, branch_id) do
    case GenServer.whereis(via_tuple(root_conversation_id)) do
      nil -> {:error, :brancher_not_found}
      pid -> GenServer.call(pid, {:abandon_branch, branch_id})
    end
  end

  @doc """
  Gets the default merge strategy configuration.

  ## Returns
  - Default merge strategy map
  """
  @spec get_default_merge_strategy() :: merge_strategy()
  def get_default_merge_strategy do
    %{
      strategy: :append,
      conflict_resolution: :keep_source,
      preserve_timestamps: true,
      merge_metadata: true
    }
  end

  ## GenServer Callbacks

  @impl true
  def init({root_conversation_id, opts}) do
    # Set up periodic cleanup
    Process.send_after(self(), :cleanup_abandoned_branches, @branch_cleanup_interval_ms)

    # Initialize branch tree
    branch_tree = %{
      root_conversation_id: root_conversation_id,
      branches: %{},
      branch_hierarchy: %{},
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Logger.info("ReqLLM conversation brancher started for #{root_conversation_id}")

    {:ok, branch_tree}
  end

  @impl true
  def handle_call({:create_branch, branch_point_index, branch_metadata}, _from, branch_tree) do
    case validate_branch_creation(branch_tree, branch_point_index) do
      :ok ->
        case create_branch_from_point(branch_tree, branch_point_index, branch_metadata) do
          {:ok, branch_id, updated_tree} ->
            Logger.info("Branch created: #{branch_id} from #{branch_tree.root_conversation_id} at index #{branch_point_index}")
            {:reply, {:ok, branch_id}, updated_tree}

          {:error, reason} ->
            Logger.error("Failed to create branch: #{inspect(reason)}")
            {:reply, {:error, reason}, branch_tree}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, branch_tree}
    end
  end

  @impl true
  def handle_call({:merge_branch, branch_id, merge_strategy}, _from, branch_tree) do
    strategy = merge_strategy || get_default_merge_strategy()

    case get_branch_info(branch_tree, branch_id) do
      {:ok, branch_info} ->
        case perform_branch_merge(branch_tree, branch_info, strategy) do
          {:ok, merge_result, updated_tree} ->
            Logger.info("Branch merged: #{branch_id} into #{branch_tree.root_conversation_id}")
            {:reply, {:ok, merge_result}, updated_tree}

          {:error, reason} ->
            Logger.error("Failed to merge branch #{branch_id}: #{inspect(reason)}")
            {:reply, {:error, reason}, branch_tree}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, branch_tree}
    end
  end

  @impl true
  def handle_call(:get_branch_tree, _from, branch_tree) do
    {:reply, {:ok, branch_tree}, branch_tree}
  end

  @impl true
  def handle_call({:abandon_branch, branch_id}, _from, branch_tree) do
    case get_branch_info(branch_tree, branch_id) do
      {:ok, branch_info} ->
        updated_branch_info = %{branch_info | status: :abandoned}
        updated_branches = Map.put(branch_tree.branches, branch_id, updated_branch_info)
        updated_tree = %{branch_tree |
          branches: updated_branches,
          updated_at: DateTime.utc_now()
        }

        Logger.info("Branch abandoned: #{branch_id}")
        {:reply, :ok, updated_tree}

      {:error, reason} ->
        {:reply, {:error, reason}, branch_tree}
    end
  end

  @impl true
  def handle_info(:cleanup_abandoned_branches, branch_tree) do
    # Clean up old abandoned branches
    cutoff_time = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)  # 24 hours ago

    {active_branches, abandoned_count} =
      Enum.reduce(branch_tree.branches, {%{}, 0}, fn {branch_id, info}, {acc, count} ->
        if info.status == :abandoned and DateTime.compare(info.created_at, cutoff_time) == :lt do
          # Remove old abandoned branch
          Logger.debug("Cleaning up abandoned branch: #{branch_id}")
          {acc, count + 1}
        else
          {Map.put(acc, branch_id, info), count}
        end
      end)

    if abandoned_count > 0 do
      Logger.info("Cleaned up #{abandoned_count} abandoned branches for #{branch_tree.root_conversation_id}")
    end

    updated_tree = %{branch_tree |
      branches: active_branches,
      updated_at: DateTime.utc_now()
    }

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_abandoned_branches, @branch_cleanup_interval_ms)

    {:noreply, updated_tree}
  end

  ## Private Functions

  # Validate branch creation parameters
  defp validate_branch_creation(branch_tree, branch_point_index) do
    cond do
      map_size(branch_tree.branches) >= @max_branch_depth ->
        {:error, :max_branches_exceeded}

      branch_point_index < 0 ->
        {:error, :invalid_branch_point}

      true ->
        # Validate that branch point exists in root conversation
        case ReqLLMConversationContext.get_conversation_history(branch_tree.root_conversation_id) do
          {:ok, messages} ->
            if branch_point_index < length(messages) do
              :ok
            else
              {:error, :branch_point_out_of_range}
            end

          {:error, reason} ->
            {:error, {:root_conversation_error, reason}}
        end
    end
  end

  # Create a branch from a specific point in the conversation
  defp create_branch_from_point(branch_tree, branch_point_index, branch_metadata) do
    case ReqLLMConversationContext.get_conversation_context(branch_tree.root_conversation_id) do
      {:ok, root_context} ->
        branch_id = generate_conversation_id("branch")

        # Create branch conversation
        case ReqLLMConversationContext.create_conversation_context(
          branch_id,
          root_context.provider,
          root_context.model,
          [
            metadata: Map.merge(root_context.metadata, branch_metadata),
            max_messages: root_context.limits.max_messages,
            max_tokens: root_context.limits.max_tokens,
            max_age_hours: root_context.limits.max_age_hours
          ]
        ) do
          {:ok, _branch_context} ->
            # Copy messages up to branch point
            messages_to_copy = Enum.take(root_context.messages, branch_point_index + 1)

            case copy_messages_to_conversation(messages_to_copy, branch_id) do
              {:ok, _} ->
                # Create branch info
                branch_info = %{
                  branch_id: branch_id,
                  parent_conversation_id: branch_tree.root_conversation_id,
                  branch_point_index: branch_point_index,
                  created_at: DateTime.utc_now(),
                  metadata: branch_metadata,
                  status: :active
                }

                # Update branch tree
                updated_branches = Map.put(branch_tree.branches, branch_id, branch_info)
                updated_hierarchy = Map.put(branch_tree.branch_hierarchy, branch_id, branch_tree.root_conversation_id)

                updated_tree = %{branch_tree |
                  branches: updated_branches,
                  branch_hierarchy: updated_hierarchy,
                  updated_at: DateTime.utc_now()
                }

                {:ok, branch_id, updated_tree}

              {:error, reason} ->
                {:error, {:copy_messages_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:create_branch_conversation_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:root_context_error, reason}}
    end
  end

  # Perform branch merge operation
  defp perform_branch_merge(branch_tree, branch_info, merge_strategy) do
    case {
      ReqLLMConversationContext.get_conversation_history(branch_tree.root_conversation_id),
      ReqLLMConversationContext.get_conversation_history(branch_info.branch_id)
    } do
      {{:ok, root_messages}, {:ok, branch_messages}} ->
        # Determine merge point and new messages
        branch_point = branch_info.branch_point_index
        root_messages_after_branch = Enum.drop(root_messages, branch_point + 1)
        branch_messages_after_branch = Enum.drop(branch_messages, branch_point + 1)

        # Apply merge strategy
        case apply_merge_strategy(
          root_messages_after_branch,
          branch_messages_after_branch,
          merge_strategy
        ) do
          {:ok, merged_messages} ->
            # Add merged messages to root conversation
            case add_merged_messages_to_root(
              branch_tree.root_conversation_id,
              merged_messages,
              branch_point
            ) do
              {:ok, _} ->
                # Mark branch as merged
                updated_branch_info = %{branch_info | status: :merged}
                updated_branches = Map.put(branch_tree.branches, branch_info.branch_id, updated_branch_info)
                updated_tree = %{branch_tree |
                  branches: updated_branches,
                  updated_at: DateTime.utc_now()
                }

                merge_result = %{
                  branch_id: branch_info.branch_id,
                  merge_strategy: merge_strategy.strategy,
                  messages_merged: length(merged_messages),
                  conflicts_resolved: count_conflicts_resolved(root_messages_after_branch, branch_messages_after_branch),
                  merged_at: DateTime.utc_now()
                }

                {:ok, merge_result, updated_tree}

              {:error, reason} ->
                {:error, {:add_merged_messages_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:merge_strategy_failed, reason}}
        end

      {{:error, reason}, _} ->
        {:error, {:root_messages_error, reason}}

      {_, {:error, reason}} ->
        {:error, {:branch_messages_error, reason}}
    end
  end

  # Apply the specified merge strategy
  defp apply_merge_strategy(root_messages, branch_messages, strategy) do
    case strategy.strategy do
      :append ->
        # Simply append branch messages after root messages
        merged = root_messages ++ branch_messages
        {:ok, merged}

      :interleave ->
        # Interleave messages by timestamp
        all_messages = root_messages ++ branch_messages
        merged = Enum.sort_by(all_messages, & &1.timestamp, DateTime)
        {:ok, merged}

      :priority_based ->
        # Use priority-based merging (keep higher priority messages)
        merged = merge_by_priority(root_messages, branch_messages, strategy)
        {:ok, merged}

      :manual ->
        # Manual merge requires external resolution
        {:error, :manual_merge_not_implemented}

      _ ->
        {:error, :unknown_merge_strategy}
    end
  end

  # Merge messages by priority (simplified implementation)
  defp merge_by_priority(root_messages, branch_messages, strategy) do
    case strategy.conflict_resolution do
      :keep_source -> root_messages ++ branch_messages
      :keep_target -> branch_messages ++ root_messages
      :merge_both ->
        # Interleave by timestamp as fallback
        all_messages = root_messages ++ branch_messages
        Enum.sort_by(all_messages, & &1.timestamp, DateTime)
      _ -> root_messages ++ branch_messages
    end
  end

  # Add merged messages to root conversation
  defp add_merged_messages_to_root(root_conversation_id, merged_messages, branch_point) do
    # For simplicity, we'll append the merged messages
    # In a more sophisticated implementation, we might replace messages after branch point
    Enum.reduce_while(merged_messages, {:ok, nil}, fn message, _acc ->
      case ReqLLMConversationContext.add_message(
        root_conversation_id,
        message.role,
        message.content,
        Map.merge(message.metadata, %{merged_from_branch: true})
      ) do
        {:ok, context} -> {:cont, {:ok, context}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Count conflicts that were resolved during merge
  defp count_conflicts_resolved(root_messages, branch_messages) do
    # Simple heuristic: count overlapping timestamps as potential conflicts
    root_timestamps = MapSet.new(root_messages, & &1.timestamp)
    branch_timestamps = MapSet.new(branch_messages, & &1.timestamp)

    MapSet.intersection(root_timestamps, branch_timestamps)
    |> MapSet.size()
  end

  # Get branch information
  defp get_branch_info(branch_tree, branch_id) do
    case Map.get(branch_tree.branches, branch_id) do
      nil -> {:error, :branch_not_found}
      info -> {:ok, info}
    end
  end

  # Copy messages to a conversation
  defp copy_messages_to_conversation(messages, target_conversation_id) do
    Enum.reduce_while(messages, {:ok, nil}, fn message, _acc ->
      case ReqLLMConversationContext.add_message(
        target_conversation_id,
        message.role,
        message.content,
        message.metadata
      ) do
        {:ok, context} -> {:cont, {:ok, context}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Generate unique conversation ID
  defp generate_conversation_id(prefix) do
    timestamp = System.system_time(:microsecond)
    random = :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)
    "#{prefix}_#{timestamp}_#{random}"
  end

  # Registry via tuple for brancher management
  defp via_tuple(root_conversation_id) do
    {:via, Registry, {DecisionEngine.ConversationRegistry, "brancher_#{root_conversation_id}"}}
  end
end
