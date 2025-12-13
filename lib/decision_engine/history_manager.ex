defmodule DecisionEngine.HistoryManager do
  @moduledoc """
  Manages analysis history with file-based persistence and in-memory caching.

  Provides CRUD operations for history entries, export functionality,
  and ensures data integrity with graceful error handling.
  """

  use GenServer
  require Logger

  @history_file "priv/history/analysis_history.json"
  @cache_table :history_cache
  @max_memory_entries 1000
  @cache_cleanup_threshold 1200  # Trigger cleanup when cache exceeds this size

  # Client API

  @doc """
  Starts the HistoryManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves a completed analysis to history.

  ## Parameters
  - analysis: Map containing analysis results with required fields:
    - scenario: String - original user scenario
    - domain: Atom - domain used for analysis
    - signals: Map - extracted signals
    - decision: Map - decision result from rule engine
    - justification: Map - LLM-generated justification
    - metadata: Map - additional tracking information

  ## Returns
  - :ok on success
  - {:error, term()} on failure
  """
  @spec save_analysis(map()) :: :ok | {:error, term()}
  def save_analysis(analysis) do
    GenServer.call(__MODULE__, {:save_analysis, analysis})
  end

  @doc """
  Loads all history entries.

  ## Returns
  - {:ok, [map()]} with list of history entries
  - {:error, term()} on failure
  """
  @spec load_history() :: {:ok, [map()]} | {:error, term()}
  def load_history do
    GenServer.call(__MODULE__, :load_history)
  end

  @doc """
  Loads paginated history entries.

  ## Parameters
  - page: Integer page number (1-based)
  - per_page: Integer number of entries per page (default 20, max 100)

  ## Returns
  - {:ok, %{entries: [map()], total: integer(), page: integer(), per_page: integer(), total_pages: integer()}}
  - {:error, term()} on failure
  """
  @spec load_history_paginated(integer(), integer()) :: {:ok, map()} | {:error, term()}
  def load_history_paginated(page \\ 1, per_page \\ 20) do
    GenServer.call(__MODULE__, {:load_history_paginated, page, per_page})
  end

  @doc """
  Gets the total count of history entries.

  ## Returns
  - {:ok, integer()} with count
  - {:error, term()} on failure
  """
  @spec get_history_count() :: {:ok, integer()} | {:error, term()}
  def get_history_count do
    GenServer.call(__MODULE__, :get_history_count)
  end

  @doc """
  Clears all history entries.

  ## Returns
  - :ok on success
  - {:error, term()} on failure
  """
  @spec clear_history() :: :ok | {:error, term()}
  def clear_history do
    GenServer.call(__MODULE__, :clear_history)
  end

  @doc """
  Deletes a specific history entry by ID.

  ## Parameters
  - entry_id: String UUID of the entry to delete

  ## Returns
  - :ok on success
  - {:error, term()} on failure
  """
  @spec delete_entry(String.t()) :: :ok | {:error, term()}
  def delete_entry(entry_id) do
    GenServer.call(__MODULE__, {:delete_entry, entry_id})
  end

  @doc """
  Exports history in the specified format.

  ## Parameters
  - format: :json | :csv - export format

  ## Returns
  - {:ok, binary()} with exported data
  - {:error, term()} on failure
  """
  @spec export_history(atom()) :: {:ok, binary()} | {:error, term()}
  def export_history(format) when format in [:json, :csv] do
    GenServer.call(__MODULE__, {:export_history, format})
  end

  @doc """
  Gets a specific history entry by ID.

  ## Parameters
  - entry_id: String UUID of the entry to retrieve

  ## Returns
  - {:ok, map()} with the entry
  - {:error, :not_found} if entry doesn't exist
  - {:error, term()} on other failures
  """
  @spec get_entry(String.t()) :: {:ok, map()} | {:error, term()}
  def get_entry(entry_id) do
    GenServer.call(__MODULE__, {:get_entry, entry_id})
  end

  @doc """
  Searches history entries by scenario text.

  ## Parameters
  - query: String to search for in scenarios

  ## Returns
  - {:ok, [map()]} with matching entries
  - {:error, term()} on failure
  """
  @spec search_history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def search_history(query) do
    GenServer.call(__MODULE__, {:search_history, query})
  end

  @doc """
  Searches history entries by scenario text with pagination.

  ## Parameters
  - query: String to search for in scenarios
  - page: Integer page number (1-based)
  - per_page: Integer number of entries per page (default 20, max 100)

  ## Returns
  - {:ok, %{entries: [map()], total: integer(), page: integer(), per_page: integer(), total_pages: integer()}}
  - {:error, term()} on failure
  """
  @spec search_history_paginated(String.t(), integer(), integer()) :: {:ok, map()} | {:error, term()}
  def search_history_paginated(query, page \\ 1, per_page \\ 20) do
    GenServer.call(__MODULE__, {:search_history_paginated, query, page, per_page})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting HistoryManager")

    # Create ETS table for caching
    :ets.new(@cache_table, [:named_table, :set, :protected])

    # Ensure history directory exists
    ensure_history_directory()

    # Load existing history into cache
    case load_history_from_file() do
      {:ok, entries} ->
        populate_cache(entries)
        Logger.info("HistoryManager started with #{length(entries)} existing entries")
        {:ok, %{entries: entries, file_available: true}}

      {:error, :enoent} ->
        Logger.info("HistoryManager started with empty history")
        {:ok, %{entries: [], file_available: true}}

      {:error, reason} ->
        Logger.warning("Failed to load history file, using in-memory only: #{inspect(reason)}")
        {:ok, %{entries: [], file_available: false}}
    end
  end

  @impl true
  def handle_call({:save_analysis, analysis}, _from, state) do
    entry = create_history_entry(analysis)

    # Add to cache
    :ets.insert(@cache_table, {entry.id, entry})

    # Update state
    new_entries = [entry | state.entries]
    new_state = %{state | entries: new_entries}

    # Check if cache cleanup is needed
    cache_size = :ets.info(@cache_table, :size)
    if cache_size > @cache_cleanup_threshold do
      cleanup_cache(new_entries)
    end

    # Persist to file if available
    case state.file_available do
      true ->
        case persist_to_file(new_entries) do
          :ok ->
            {:reply, :ok, new_state}
          {:error, reason} ->
            Logger.warning("Failed to persist history to file: #{inspect(reason)}")
            # Continue with in-memory storage
            {:reply, :ok, %{new_state | file_available: false}}
        end

      false ->
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:load_history, _from, state) do
    # Return entries in reverse chronological order (newest first)
    sorted_entries = Enum.sort_by(state.entries, & &1.timestamp, {:desc, DateTime})
    {:reply, {:ok, sorted_entries}, state}
  end

  @impl true
  def handle_call({:load_history_paginated, page, per_page}, _from, state) do
    # Validate pagination parameters
    per_page = min(max(per_page, 1), 100)  # Limit per_page to 1-100
    page = max(page, 1)  # Ensure page is at least 1

    # Sort entries in reverse chronological order (newest first)
    sorted_entries = Enum.sort_by(state.entries, & &1.timestamp, {:desc, DateTime})
    total = length(sorted_entries)
    total_pages = max(ceil(total / per_page), 1)

    # Calculate pagination
    start_index = (page - 1) * per_page
    paginated_entries =
      sorted_entries
      |> Enum.drop(start_index)
      |> Enum.take(per_page)

    result = %{
      entries: paginated_entries,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_history_count, _from, state) do
    {:reply, {:ok, length(state.entries)}, state}
  end

  @impl true
  def handle_call(:clear_history, _from, state) do
    # Clear cache
    :ets.delete_all_objects(@cache_table)

    # Clear file if available
    case state.file_available do
      true ->
        case persist_to_file([]) do
          :ok ->
            {:reply, :ok, %{state | entries: []}}
          {:error, reason} ->
            Logger.warning("Failed to clear history file: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end

      false ->
        {:reply, :ok, %{state | entries: []}}
    end
  end

  @impl true
  def handle_call({:delete_entry, entry_id}, _from, state) do
    # Remove from cache
    :ets.delete(@cache_table, entry_id)

    # Remove from state
    new_entries = Enum.reject(state.entries, &(&1.id == entry_id))
    new_state = %{state | entries: new_entries}

    # Persist to file if available
    case state.file_available do
      true ->
        case persist_to_file(new_entries) do
          :ok ->
            {:reply, :ok, new_state}
          {:error, reason} ->
            Logger.warning("Failed to persist after deletion: #{inspect(reason)}")
            {:reply, :ok, %{new_state | file_available: false}}
        end

      false ->
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:export_history, format}, _from, state) do
    # Performance monitoring for export operations
    start_time = System.monotonic_time(:millisecond)
    entry_count = length(state.entries)

    Logger.info("Starting export of #{entry_count} entries in #{format} format")

    case export_entries(state.entries, format) do
      {:ok, data} ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time
        data_size = byte_size(data)

        Logger.info("Export completed: #{entry_count} entries, #{data_size} bytes, #{duration}ms")

        # Add performance metadata to response
        result = %{
          data: data,
          metadata: %{
            entry_count: entry_count,
            data_size: data_size,
            processing_time_ms: duration,
            format: format
          }
        }

        {:reply, {:ok, result}, state}
      {:error, reason} ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time

        Logger.warning("Export failed after #{duration}ms: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_entry, entry_id}, _from, state) do
    case :ets.lookup(@cache_table, entry_id) do
      [{^entry_id, entry}] ->
        {:reply, {:ok, entry}, state}
      [] ->
        # Fallback to searching in state entries
        case Enum.find(state.entries, &(&1.id == entry_id)) do
          nil -> {:reply, {:error, :not_found}, state}
          entry -> {:reply, {:ok, entry}, state}
        end
    end
  end

  @impl true
  def handle_call({:search_history, query}, _from, state) do
    query_lower = String.downcase(query)

    matching_entries =
      state.entries
      |> Enum.filter(fn entry ->
        scenario_lower = String.downcase(entry.scenario)
        String.contains?(scenario_lower, query_lower)
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    {:reply, {:ok, matching_entries}, state}
  end

  @impl true
  def handle_call({:search_history_paginated, query, page, per_page}, _from, state) do
    # Validate pagination parameters
    per_page = min(max(per_page, 1), 100)  # Limit per_page to 1-100
    page = max(page, 1)  # Ensure page is at least 1

    query_lower = String.downcase(query)

    # Filter and sort matching entries
    matching_entries =
      state.entries
      |> Enum.filter(fn entry ->
        scenario_lower = String.downcase(entry.scenario)
        String.contains?(scenario_lower, query_lower)
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    total = length(matching_entries)
    total_pages = max(ceil(total / per_page), 1)

    # Calculate pagination
    start_index = (page - 1) * per_page
    paginated_entries =
      matching_entries
      |> Enum.drop(start_index)
      |> Enum.take(per_page)

    result = %{
      entries: paginated_entries,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages,
      query: query
    }

    {:reply, {:ok, result}, state}
  end

  # Private Functions

  defp ensure_history_directory do
    history_dir = Path.dirname(@history_file)
    File.mkdir_p!(history_dir)
  end

  defp create_history_entry(analysis) do
    %{
      id: generate_uuid(),
      timestamp: DateTime.utc_now(),
      scenario: analysis[:scenario] || analysis["scenario"] || "",
      domain: analysis[:domain] || analysis["domain"] || :unknown,
      signals: analysis[:signals] || analysis["signals"] || %{},
      decision: analysis[:decision] || analysis["decision"] || %{},
      justification: analysis[:justification] || analysis["justification"] || %{},
      metadata: analysis[:metadata] || analysis["metadata"] || %{
        provider: "unknown",
        model: "unknown",
        processing_time: 0,
        streaming_enabled: false
      }
    }
  end

  defp load_history_from_file do
    case File.read(@history_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"entries" => entries}} ->
            parsed_entries = Enum.map(entries, &parse_history_entry/1)
            {:ok, parsed_entries}

          {:ok, %{}} ->
            {:ok, []}

          {:error, reason} ->
            {:error, {:json_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_history_entry(entry) do
    %{
      id: entry["id"],
      timestamp: parse_timestamp(entry["timestamp"]),
      scenario: entry["scenario"],
      domain: String.to_atom(entry["domain"]),
      signals: entry["signals"],
      decision: entry["decision"],
      justification: entry["justification"],
      metadata: entry["metadata"] || %{}
    }
  end

  defp parse_timestamp(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp populate_cache(entries) do
    # Limit cache size to prevent memory issues
    limited_entries = Enum.take(entries, @max_memory_entries)

    Enum.each(limited_entries, fn entry ->
      :ets.insert(@cache_table, {entry.id, entry})
    end)
  end

  defp persist_to_file(entries) do
    history_data = %{
      version: "1.0",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      entries: Enum.map(entries, &serialize_entry/1)
    }

    case Jason.encode(history_data, pretty: true) do
      {:ok, json} ->
        File.write(@history_file, json)

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  end

  defp serialize_entry(entry) do
    %{
      "id" => entry.id,
      "timestamp" => DateTime.to_iso8601(entry.timestamp),
      "scenario" => entry.scenario,
      "domain" => Atom.to_string(entry.domain),
      "signals" => entry.signals,
      "decision" => entry.decision,
      "justification" => entry.justification,
      "metadata" => entry.metadata
    }
  end

  defp export_entries(entries, :json) do
    case Jason.encode(entries, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode_error, reason}}
    end
  end

  defp export_entries(entries, :csv) do
    try do
      headers = ["ID", "Timestamp", "Domain", "Scenario", "Decision Pattern", "Decision Outcome", "Score"]

      csv_rows =
        entries
        |> Enum.map(&entry_to_csv_row/1)
        |> Enum.join("\n")

      csv_content = Enum.join(headers, ",") <> "\n" <> csv_rows
      {:ok, csv_content}
    rescue
      error ->
        {:error, {:csv_generation_error, error}}
    end
  end

  defp entry_to_csv_row(entry) do
    [
      escape_csv_field(entry.id),
      escape_csv_field(DateTime.to_iso8601(entry.timestamp)),
      escape_csv_field(Atom.to_string(entry.domain)),
      escape_csv_field(entry.scenario),
      escape_csv_field(get_in(entry.decision, ["pattern_id"]) || "unknown"),
      escape_csv_field(get_in(entry.decision, ["outcome"]) || "unknown"),
      escape_csv_field(to_string(get_in(entry.decision, ["score"]) || "N/A"))
    ]
    |> Enum.join(",")
  end

  defp escape_csv_field(field) when is_binary(field) do
    escaped = String.replace(field, "\"", "\"\"")
    "\"#{escaped}\""
  end
  defp escape_csv_field(field), do: "\"#{field}\""

  defp cleanup_cache(entries) do
    Logger.info("Cleaning up cache, current size: #{:ets.info(@cache_table, :size)}")

    # Clear the cache and repopulate with most recent entries
    :ets.delete_all_objects(@cache_table)

    # Keep only the most recent entries in cache
    recent_entries =
      entries
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(@max_memory_entries)

    populate_cache(recent_entries)

    Logger.info("Cache cleanup completed, new size: #{:ets.info(@cache_table, :size)}")
  end

  defp generate_uuid do
    # Generate a simple UUID using Elixir's built-in functions
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
  end
end
