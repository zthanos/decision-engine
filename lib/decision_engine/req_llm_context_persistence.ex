defmodule DecisionEngine.ReqLLMContextPersistence do
  @moduledoc """
  Context persistence mechanisms for ReqLLM conversations.

  This module provides conversation context persistence, retrieval and restoration,
  and context cleanup and lifecycle management. It ensures conversations can be
  saved, restored, and managed across extended time periods for long-running
  AI workflows and reflection processes.
  """

  use GenServer
  require Logger

  alias DecisionEngine.ReqLLMConversationContext

  @typedoc """
  Persistence configuration.
  """
  @type persistence_config :: %{
    storage_backend: :file | :memory | :database,
    storage_path: String.t() | nil,
    compression: boolean(),
    encryption: boolean(),
    retention_days: integer(),
    cleanup_interval_hours: integer()
  }

  @typedoc """
  Persisted conversation data.
  """
  @type persisted_conversation :: %{
    conversation_id: String.t(),
    context_data: map(),
    persisted_at: DateTime.t(),
    metadata: map(),
    checksum: String.t()
  }

  # Configuration constants
  @default_storage_path "priv/conversations"
  @default_retention_days 30
  @default_cleanup_interval_hours 24
  @cleanup_batch_size 100

  ## Public API

  @doc """
  Starts the context persistence manager.

  ## Parameters
  - opts: Optional configuration (storage_backend, storage_path, etc.)

  ## Returns
  - {:ok, pid} on successful start
  - {:error, reason} if start fails
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Persists a conversation context to storage.

  ## Parameters
  - conversation_id: The conversation to persist
  - opts: Optional persistence options (force_save, metadata, etc.)

  ## Returns
  - {:ok, persisted_conversation} on success
  - {:error, reason} on failure
  """
  @spec persist_conversation_context(String.t(), keyword()) ::
    {:ok, persisted_conversation()} | {:error, term()}
  def persist_conversation_context(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:persist_conversation, conversation_id, opts})
  end

  @doc """
  Restores a conversation context from storage.

  ## Parameters
  - conversation_id: The conversation to restore
  - opts: Optional restoration options (validate_checksum, etc.)

  ## Returns
  - {:ok, context_state} on success
  - {:error, reason} on failure
  """
  @spec restore_conversation_context(String.t(), keyword()) ::
    {:ok, map()} | {:error, term()}
  def restore_conversation_context(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:restore_conversation, conversation_id, opts})
  end

  @doc """
  Lists all persisted conversations.

  ## Parameters
  - opts: Optional filtering options (created_after, created_before, etc.)

  ## Returns
  - {:ok, [conversation_info]} list of persisted conversation info
  - {:error, reason} on failure
  """
  @spec list_persisted_conversations(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_persisted_conversations(opts \\ []) do
    GenServer.call(__MODULE__, {:list_conversations, opts})
  end

  @doc """
  Deletes a persisted conversation from storage.

  ## Parameters
  - conversation_id: The conversation to delete

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec delete_persisted_conversation(String.t()) :: :ok | {:error, term()}
  def delete_persisted_conversation(conversation_id) do
    GenServer.call(__MODULE__, {:delete_conversation, conversation_id})
  end

  @doc """
  Performs cleanup of old persisted conversations.

  ## Parameters
  - opts: Optional cleanup options (force_cleanup, retention_override, etc.)

  ## Returns
  - {:ok, cleanup_stats} with cleanup statistics
  - {:error, reason} on failure
  """
  @spec cleanup_old_conversations(keyword()) :: {:ok, map()} | {:error, term()}
  def cleanup_old_conversations(opts \\ []) do
    GenServer.call(__MODULE__, {:cleanup_conversations, opts})
  end

  @doc """
  Gets persistence statistics and storage information.

  ## Returns
  - {:ok, stats} with persistence statistics
  - {:error, reason} on failure
  """
  @spec get_persistence_stats() :: {:ok, map()} | {:error, term()}
  def get_persistence_stats do
    GenServer.call(__MODULE__, :get_persistence_stats)
  end

  @doc """
  Validates the integrity of a persisted conversation.

  ## Parameters
  - conversation_id: The conversation to validate

  ## Returns
  - :ok if validation passes
  - {:error, validation_errors} if validation fails
  """
  @spec validate_persisted_conversation(String.t()) :: :ok | {:error, [String.t()]}
  def validate_persisted_conversation(conversation_id) do
    GenServer.call(__MODULE__, {:validate_conversation, conversation_id})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Initialize persistence configuration
    config = %{
      storage_backend: Keyword.get(opts, :storage_backend, :file),
      storage_path: Keyword.get(opts, :storage_path, @default_storage_path),
      compression: Keyword.get(opts, :compression, true),
      encryption: Keyword.get(opts, :encryption, false),
      retention_days: Keyword.get(opts, :retention_days, @default_retention_days),
      cleanup_interval_hours: Keyword.get(opts, :cleanup_interval_hours, @default_cleanup_interval_hours)
    }

    # Initialize storage backend
    case initialize_storage_backend(config) do
      :ok ->
        # Schedule periodic cleanup
        cleanup_interval_ms = config.cleanup_interval_hours * 60 * 60 * 1000
        Process.send_after(self(), :periodic_cleanup, cleanup_interval_ms)

        Logger.info("ReqLLM context persistence started with backend: #{config.storage_backend}")

        {:ok, config}

      {:error, reason} ->
        Logger.error("Failed to initialize persistence storage: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:persist_conversation, conversation_id, opts}, _from, config) do
    case ReqLLMConversationContext.get_conversation_context(conversation_id) do
      {:ok, context} ->
        case persist_context_to_storage(context, config, opts) do
          {:ok, persisted_data} ->
            Logger.debug("Conversation persisted: #{conversation_id}")
            {:reply, {:ok, persisted_data}, config}

          {:error, reason} ->
            Logger.error("Failed to persist conversation #{conversation_id}: #{inspect(reason)}")
            {:reply, {:error, reason}, config}
        end

      {:error, reason} ->
        {:reply, {:error, {:context_not_found, reason}}, config}
    end
  end

  @impl true
  def handle_call({:restore_conversation, conversation_id, opts}, _from, config) do
    case load_context_from_storage(conversation_id, config, opts) do
      {:ok, context_data} ->
        case restore_context_to_memory(conversation_id, context_data, opts) do
          {:ok, restored_context} ->
            Logger.debug("Conversation restored: #{conversation_id}")
            {:reply, {:ok, restored_context}, config}

          {:error, reason} ->
            Logger.error("Failed to restore conversation to memory #{conversation_id}: #{inspect(reason)}")
            {:reply, {:error, reason}, config}
        end

      {:error, reason} ->
        Logger.error("Failed to load conversation from storage #{conversation_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, config}
    end
  end

  @impl true
  def handle_call({:list_conversations, opts}, _from, config) do
    case list_stored_conversations(config, opts) do
      {:ok, conversations} ->
        {:reply, {:ok, conversations}, config}

      {:error, reason} ->
        {:reply, {:error, reason}, config}
    end
  end

  @impl true
  def handle_call({:delete_conversation, conversation_id}, _from, config) do
    case delete_from_storage(conversation_id, config) do
      :ok ->
        Logger.debug("Conversation deleted from storage: #{conversation_id}")
        {:reply, :ok, config}

      {:error, reason} ->
        Logger.error("Failed to delete conversation #{conversation_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, config}
    end
  end

  @impl true
  def handle_call({:cleanup_conversations, opts}, _from, config) do
    case perform_cleanup(config, opts) do
      {:ok, stats} ->
        Logger.info("Conversation cleanup completed: #{inspect(stats)}")
        {:reply, {:ok, stats}, config}

      {:error, reason} ->
        Logger.error("Conversation cleanup failed: #{inspect(reason)}")
        {:reply, {:error, reason}, config}
    end
  end

  @impl true
  def handle_call(:get_persistence_stats, _from, config) do
    case calculate_persistence_stats(config) do
      {:ok, stats} ->
        {:reply, {:ok, stats}, config}

      {:error, reason} ->
        {:reply, {:error, reason}, config}
    end
  end

  @impl true
  def handle_call({:validate_conversation, conversation_id}, _from, config) do
    case validate_stored_conversation(conversation_id, config) do
      :ok ->
        {:reply, :ok, config}

      {:error, errors} ->
        {:reply, {:error, errors}, config}
    end
  end

  @impl true
  def handle_info(:periodic_cleanup, config) do
    # Perform periodic cleanup
    case perform_cleanup(config, []) do
      {:ok, stats} ->
        if stats.deleted_count > 0 do
          Logger.info("Periodic cleanup completed: #{stats.deleted_count} conversations removed")
        end

      {:error, reason} ->
        Logger.warning("Periodic cleanup failed: #{inspect(reason)}")
    end

    # Schedule next cleanup
    cleanup_interval_ms = config.cleanup_interval_hours * 60 * 60 * 1000
    Process.send_after(self(), :periodic_cleanup, cleanup_interval_ms)

    {:noreply, config}
  end

  ## Private Functions

  # Initialize storage backend
  defp initialize_storage_backend(config) do
    case config.storage_backend do
      :file ->
        initialize_file_storage(config.storage_path)

      :memory ->
        initialize_memory_storage()

      :database ->
        initialize_database_storage(config)

      _ ->
        {:error, :unsupported_storage_backend}
    end
  end

  # Initialize file-based storage
  defp initialize_file_storage(storage_path) do
    case File.mkdir_p(storage_path) do
      :ok ->
        # Test write permissions
        test_file = Path.join(storage_path, ".write_test")
        case File.write(test_file, "test") do
          :ok ->
            File.rm(test_file)
            :ok

          {:error, reason} ->
            {:error, {:storage_not_writable, reason}}
        end

      {:error, reason} ->
        {:error, {:storage_creation_failed, reason}}
    end
  end

  # Initialize memory-based storage (using ETS)
  defp initialize_memory_storage do
    table_name = :req_llm_conversations
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  end

  # Initialize database storage (placeholder)
  defp initialize_database_storage(_config) do
    # Placeholder for database initialization
    # In a real implementation, this would set up database connections
    {:error, :database_storage_not_implemented}
  end

  # Persist context to storage
  defp persist_context_to_storage(context, config, opts) do
    # Prepare data for persistence
    context_data = prepare_context_for_persistence(context, opts)
    checksum = calculate_context_checksum(context_data)

    persisted_data = %{
      conversation_id: context.conversation_id,
      context_data: context_data,
      persisted_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{}),
      checksum: checksum
    }

    # Apply compression if enabled
    final_data = if config.compression do
      compress_context_data(persisted_data)
    else
      persisted_data
    end

    # Apply encryption if enabled
    final_data = if config.encryption do
      encrypt_context_data(final_data, config)
    else
      final_data
    end

    # Store using appropriate backend
    case store_context_data(context.conversation_id, final_data, config) do
      :ok -> {:ok, persisted_data}
      {:error, reason} -> {:error, reason}
    end
  end

  # Load context from storage
  defp load_context_from_storage(conversation_id, config, opts) do
    case load_context_data(conversation_id, config) do
      {:ok, stored_data} ->
        # Apply decryption if enabled
        decrypted_data = if config.encryption do
          decrypt_context_data(stored_data, config)
        else
          stored_data
        end

        # Apply decompression if enabled
        decompressed_data = if config.compression do
          decompress_context_data(decrypted_data)
        else
          decrypted_data
        end

        # Validate checksum if requested
        if Keyword.get(opts, :validate_checksum, true) do
          case validate_context_checksum(decompressed_data) do
            :ok -> {:ok, decompressed_data.context_data}
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, decompressed_data.context_data}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Restore context to memory (recreate conversation)
  defp restore_context_to_memory(conversation_id, context_data, _opts) do
    # Create conversation context with restored data
    case ReqLLMConversationContext.create_conversation_context(
      conversation_id,
      context_data.provider,
      context_data.model,
      [
        metadata: context_data.metadata,
        max_messages: context_data.limits.max_messages,
        max_tokens: context_data.limits.max_tokens,
        max_age_hours: context_data.limits.max_age_hours
      ]
    ) do
      {:ok, _new_context} ->
        # Add all messages back
        case restore_messages_to_conversation(conversation_id, context_data.messages) do
          {:ok, final_context} ->
            {:ok, final_context}

          {:error, reason} ->
            {:error, {:message_restoration_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:context_creation_failed, reason}}
    end
  end

  # Store context data using appropriate backend
  defp store_context_data(conversation_id, data, config) do
    case config.storage_backend do
      :file ->
        store_to_file(conversation_id, data, config.storage_path)

      :memory ->
        store_to_memory(conversation_id, data)

      :database ->
        store_to_database(conversation_id, data, config)

      _ ->
        {:error, :unsupported_storage_backend}
    end
  end

  # Load context data using appropriate backend
  defp load_context_data(conversation_id, config) do
    case config.storage_backend do
      :file ->
        load_from_file(conversation_id, config.storage_path)

      :memory ->
        load_from_memory(conversation_id)

      :database ->
        load_from_database(conversation_id, config)

      _ ->
        {:error, :unsupported_storage_backend}
    end
  end

  # File storage operations
  defp store_to_file(conversation_id, data, storage_path) do
    filename = "#{conversation_id}.json"
    filepath = Path.join(storage_path, filename)

    case Jason.encode(data) do
      {:ok, json_data} ->
        case File.write(filepath, json_data) do
          :ok -> :ok
          {:error, reason} -> {:error, {:file_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end

  defp load_from_file(conversation_id, storage_path) do
    filename = "#{conversation_id}.json"
    filepath = Path.join(storage_path, filename)

    case File.read(filepath) do
      {:ok, json_data} ->
        case Jason.decode(json_data, keys: :atoms) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode_failed, reason}}
        end

      {:error, :enoent} ->
        {:error, :conversation_not_found}

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  # Memory storage operations
  defp store_to_memory(conversation_id, data) do
    :ets.insert(:req_llm_conversations, {conversation_id, data})
    :ok
  end

  defp load_from_memory(conversation_id) do
    case :ets.lookup(:req_llm_conversations, conversation_id) do
      [{^conversation_id, data}] -> {:ok, data}
      [] -> {:error, :conversation_not_found}
    end
  end

  # Database storage operations (placeholder)
  defp store_to_database(_conversation_id, _data, _config) do
    {:error, :database_storage_not_implemented}
  end

  defp load_from_database(_conversation_id, _config) do
    {:error, :database_storage_not_implemented}
  end

  # Delete from storage
  defp delete_from_storage(conversation_id, config) do
    case config.storage_backend do
      :file ->
        filename = "#{conversation_id}.json"
        filepath = Path.join(config.storage_path, filename)
        case File.rm(filepath) do
          :ok -> :ok
          {:error, :enoent} -> :ok  # Already deleted
          {:error, reason} -> {:error, reason}
        end

      :memory ->
        :ets.delete(:req_llm_conversations, conversation_id)
        :ok

      :database ->
        {:error, :database_storage_not_implemented}

      _ ->
        {:error, :unsupported_storage_backend}
    end
  end

  # List stored conversations
  defp list_stored_conversations(config, opts) do
    case config.storage_backend do
      :file ->
        list_file_conversations(config.storage_path, opts)

      :memory ->
        list_memory_conversations(opts)

      :database ->
        {:error, :database_storage_not_implemented}

      _ ->
        {:error, :unsupported_storage_backend}
    end
  end

  defp list_file_conversations(storage_path, opts) do
    case File.ls(storage_path) do
      {:ok, files} ->
        conversations =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn filename ->
            conversation_id = String.replace_suffix(filename, ".json", "")
            filepath = Path.join(storage_path, filename)

            case File.stat(filepath) do
              {:ok, %{mtime: mtime, size: size}} ->
                %{
                  conversation_id: conversation_id,
                  file_size: size,
                  modified_at: NaiveDateTime.from_erl!(mtime) |> DateTime.from_naive!("Etc/UTC")
                }

              {:error, _} -> nil
            end
          end)
          |> Enum.filter(&(&1 != nil))
          |> apply_conversation_filters(opts)

        {:ok, conversations}

      {:error, reason} ->
        {:error, {:list_files_failed, reason}}
    end
  end

  defp list_memory_conversations(opts) do
    conversations =
      :ets.tab2list(:req_llm_conversations)
      |> Enum.map(fn {conversation_id, data} ->
        %{
          conversation_id: conversation_id,
          persisted_at: data.persisted_at,
          metadata: data.metadata
        }
      end)
      |> apply_conversation_filters(opts)

    {:ok, conversations}
  end

  # Apply filters to conversation list
  defp apply_conversation_filters(conversations, opts) do
    conversations
    |> filter_by_date_range(opts)
    |> Enum.take(Keyword.get(opts, :limit, 1000))
  end

  defp filter_by_date_range(conversations, opts) do
    created_after = Keyword.get(opts, :created_after)
    created_before = Keyword.get(opts, :created_before)

    conversations
    |> Enum.filter(fn conv ->
      date = Map.get(conv, :persisted_at) || Map.get(conv, :modified_at)

      cond do
        created_after && DateTime.compare(date, created_after) == :lt -> false
        created_before && DateTime.compare(date, created_before) == :gt -> false
        true -> true
      end
    end)
  end

  # Perform cleanup of old conversations
  defp perform_cleanup(config, opts) do
    retention_days = Keyword.get(opts, :retention_override, config.retention_days)
    cutoff_date = DateTime.add(DateTime.utc_now(), -retention_days * 24 * 3600, :second)

    case list_stored_conversations(config, [created_before: cutoff_date]) do
      {:ok, old_conversations} ->
        deleted_count =
          old_conversations
          |> Enum.take(@cleanup_batch_size)
          |> Enum.reduce(0, fn conv, acc ->
            case delete_from_storage(conv.conversation_id, config) do
              :ok -> acc + 1
              {:error, _} -> acc
            end
          end)

        stats = %{
          deleted_count: deleted_count,
          retention_days: retention_days,
          cutoff_date: cutoff_date,
          cleanup_at: DateTime.utc_now()
        }

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Calculate persistence statistics
  defp calculate_persistence_stats(config) do
    case list_stored_conversations(config, []) do
      {:ok, conversations} ->
        total_count = length(conversations)

        # Calculate storage size for file backend
        total_size = case config.storage_backend do
          :file ->
            conversations
            |> Enum.reduce(0, fn conv, acc ->
              acc + Map.get(conv, :file_size, 0)
            end)

          _ -> 0
        end

        stats = %{
          total_conversations: total_count,
          storage_backend: config.storage_backend,
          total_storage_bytes: total_size,
          retention_days: config.retention_days,
          compression_enabled: config.compression,
          encryption_enabled: config.encryption
        }

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Validate stored conversation integrity
  defp validate_stored_conversation(conversation_id, config) do
    case load_context_from_storage(conversation_id, config, [validate_checksum: true]) do
      {:ok, _context_data} -> :ok
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  # Prepare context for persistence
  defp prepare_context_for_persistence(context, _opts) do
    # Remove any non-serializable data and prepare for storage
    %{
      conversation_id: context.conversation_id,
      messages: context.messages,
      provider: context.provider,
      model: context.model,
      created_at: context.created_at,
      updated_at: context.updated_at,
      metadata: context.metadata,
      validation: context.validation,
      limits: context.limits
    }
  end

  # Calculate checksum for context data
  defp calculate_context_checksum(context_data) do
    context_data
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  # Validate context checksum
  defp validate_context_checksum(persisted_data) do
    expected_checksum = calculate_context_checksum(persisted_data.context_data)

    if expected_checksum == persisted_data.checksum do
      :ok
    else
      {:error, :checksum_mismatch}
    end
  end

  # Compression operations (placeholder)
  defp compress_context_data(data) do
    # In a real implementation, this would use :zlib or similar
    Map.put(data, :compressed, true)
  end

  defp decompress_context_data(data) do
    # In a real implementation, this would decompress the data
    Map.delete(data, :compressed)
  end

  # Encryption operations (placeholder)
  defp encrypt_context_data(data, _config) do
    # In a real implementation, this would encrypt sensitive data
    Map.put(data, :encrypted, true)
  end

  defp decrypt_context_data(data, _config) do
    # In a real implementation, this would decrypt the data
    Map.delete(data, :encrypted)
  end

  # Restore messages to conversation
  defp restore_messages_to_conversation(conversation_id, messages) do
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
end
