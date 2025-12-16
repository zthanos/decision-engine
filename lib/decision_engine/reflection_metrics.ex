# lib/decision_engine/reflection_metrics.ex
defmodule DecisionEngine.ReflectionMetrics do
  @moduledoc """
  Manages reflection system metrics collection, aggregation, and reporting.

  This module provides comprehensive metrics tracking for the agentic reflection
  pattern implementation, including quality scores, improvement tracking, and
  performance statistics.
  """

  use GenServer
  require Logger

  @metrics_version "1.0"

  # Metric types
  @quality_metrics [:completeness, :accuracy, :consistency, :usability, :overall]
  @performance_metrics [:processing_time_ms, :iteration_count, :llm_calls, :memory_usage_mb]
  @improvement_metrics [:quality_delta, :improvement_percentage, :successful_iterations]

  # Client API

  @doc """
  Starts the Reflection Metrics Manager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records the start of a reflection process.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - initial_config: The initial domain configuration
  - metadata: Additional process metadata

  ## Returns
  - :ok always
  """
  @spec start_reflection_process(String.t(), map(), map()) :: :ok
  def start_reflection_process(process_id, initial_config, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:start_process, process_id, initial_config, metadata})
  end

  @doc """
  Records quality scores for a reflection iteration.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - iteration: Iteration number (0 for initial, 1+ for reflections)
  - quality_scores: Map of quality metric scores
  - feedback: Optional feedback generated during evaluation

  ## Returns
  - :ok always
  """
  @spec record_quality_scores(String.t(), integer(), map(), list()) :: :ok
  def record_quality_scores(process_id, iteration, quality_scores, feedback \\ []) do
    GenServer.cast(__MODULE__, {:record_quality, process_id, iteration, quality_scores, feedback})
  end

  @doc """
  Records performance metrics for a reflection process.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - performance_data: Map containing performance metrics

  ## Returns
  - :ok always
  """
  @spec record_performance_metrics(String.t(), map()) :: :ok
  def record_performance_metrics(process_id, performance_data) do
    GenServer.cast(__MODULE__, {:record_performance, process_id, performance_data})
  end

  @doc """
  Records the completion of a reflection process.

  ## Parameters
  - process_id: Unique identifier for the reflection process
  - final_config: The final refined domain configuration
  - success: Whether the process completed successfully
  - error_reason: Optional error reason if process failed

  ## Returns
  - :ok always
  """
  @spec complete_reflection_process(String.t(), map(), boolean(), String.t() | nil) :: :ok
  def complete_reflection_process(process_id, final_config, success, error_reason \\ nil) do
    GenServer.cast(__MODULE__, {:complete_process, process_id, final_config, success, error_reason})
  end

  @doc """
  Gets metrics for a specific reflection process.

  ## Parameters
  - process_id: Unique identifier for the reflection process

  ## Returns
  - {:ok, metrics} with process metrics
  - {:error, :not_found} if process not found
  """
  @spec get_process_metrics(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_process_metrics(process_id) do
    GenServer.call(__MODULE__, {:get_process_metrics, process_id})
  end

  @doc """
  Gets aggregated metrics across all reflection processes.

  ## Parameters
  - time_range: Optional time range filter (:last_hour, :last_day, :last_week, :all)

  ## Returns
  - {:ok, aggregated_metrics} with system-wide metrics
  """
  @spec get_aggregated_metrics(atom()) :: {:ok, map()}
  def get_aggregated_metrics(time_range \\ :all) do
    GenServer.call(__MODULE__, {:get_aggregated_metrics, time_range})
  end

  @doc """
  Gets quality improvement statistics.

  ## Returns
  - {:ok, improvement_stats} with quality improvement analysis
  """
  @spec get_improvement_statistics() :: {:ok, map()}
  def get_improvement_statistics() do
    GenServer.call(__MODULE__, :get_improvement_statistics)
  end

  @doc """
  Exports metrics data for analysis or reporting.

  ## Parameters
  - format: Export format (:json, :csv)
  - time_range: Time range filter

  ## Returns
  - {:ok, exported_data} with formatted metrics data
  - {:error, reason} on failure
  """
  @spec export_metrics(atom(), atom()) :: {:ok, String.t()} | {:error, term()}
  def export_metrics(format \\ :json, time_range \\ :all) do
    GenServer.call(__MODULE__, {:export_metrics, format, time_range})
  end

  @doc """
  Clears old metrics data beyond retention period.

  ## Parameters
  - retention_days: Number of days to retain metrics (default: 30)

  ## Returns
  - {:ok, cleared_count} with number of cleared records
  """
  @spec cleanup_old_metrics(integer()) :: {:ok, integer()}
  def cleanup_old_metrics(retention_days \\ 30) do
    GenServer.call(__MODULE__, {:cleanup_metrics, retention_days})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    state = %{
      active_processes: %{},  # process_id -> process_data
      completed_processes: [],  # list of completed process data
      aggregated_stats: initialize_aggregated_stats(),
      metrics_file_path: get_metrics_file_path()
    }

    # Load existing metrics on startup
    case load_metrics_from_storage(state.metrics_file_path) do
      {:ok, loaded_data} ->
        Logger.info("Loaded reflection metrics from storage")
        {:ok, Map.merge(state, loaded_data)}

      {:error, reason} ->
        Logger.info("Starting with fresh reflection metrics: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:start_process, process_id, initial_config, metadata}, state) do
    process_data = %{
      process_id: process_id,
      started_at: DateTime.utc_now(),
      initial_config: initial_config,
      metadata: metadata,
      iterations: [],
      performance_metrics: %{},
      status: :active
    }

    new_active = Map.put(state.active_processes, process_id, process_data)
    new_state = %{state | active_processes: new_active}

    Logger.info("Started tracking reflection process: #{process_id}")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_quality, process_id, iteration, quality_scores, feedback}, state) do
    case Map.get(state.active_processes, process_id) do
      nil ->
        Logger.warning("Attempted to record quality for unknown process: #{process_id}")
        {:noreply, state}

      process_data ->
        iteration_data = %{
          iteration: iteration,
          timestamp: DateTime.utc_now(),
          quality_scores: quality_scores,
          feedback: feedback
        }

        updated_iterations = [iteration_data | process_data.iterations]
        updated_process = %{process_data | iterations: updated_iterations}
        new_active = Map.put(state.active_processes, process_id, updated_process)

        Logger.debug("Recorded quality scores for process #{process_id}, iteration #{iteration}")
        {:noreply, %{state | active_processes: new_active}}
    end
  end

  @impl true
  def handle_cast({:record_performance, process_id, performance_data}, state) do
    case Map.get(state.active_processes, process_id) do
      nil ->
        Logger.warning("Attempted to record performance for unknown process: #{process_id}")
        {:noreply, state}

      process_data ->
        updated_performance = Map.merge(process_data.performance_metrics, performance_data)
        updated_process = %{process_data | performance_metrics: updated_performance}
        new_active = Map.put(state.active_processes, process_id, updated_process)

        Logger.debug("Recorded performance metrics for process #{process_id}")
        {:noreply, %{state | active_processes: new_active}}
    end
  end

  @impl true
  def handle_cast({:complete_process, process_id, final_config, success, error_reason}, state) do
    case Map.get(state.active_processes, process_id) do
      nil ->
        Logger.warning("Attempted to complete unknown process: #{process_id}")
        {:noreply, state}

      process_data ->
        completed_data = process_data
        |> Map.put(:completed_at, DateTime.utc_now())
        |> Map.put(:final_config, final_config)
        |> Map.put(:success, success)
        |> Map.put(:error_reason, error_reason)
        |> Map.put(:status, :completed)

        # Calculate improvement metrics
        improvement_metrics = calculate_improvement_metrics(completed_data)
        completed_with_improvement = Map.put(completed_data, :improvement_metrics, improvement_metrics)

        # Update state
        new_active = Map.delete(state.active_processes, process_id)
        new_completed = [completed_with_improvement | state.completed_processes]
        new_aggregated = update_aggregated_stats(state.aggregated_stats, completed_with_improvement)

        new_state = %{state |
          active_processes: new_active,
          completed_processes: new_completed,
          aggregated_stats: new_aggregated
        }

        # Persist metrics
        save_metrics_to_storage(new_state, state.metrics_file_path)

        Logger.info("Completed reflection process: #{process_id}, success: #{success}")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:get_process_metrics, process_id}, _from, state) do
    # Check both active and completed processes
    result = case Map.get(state.active_processes, process_id) do
      nil ->
        case Enum.find(state.completed_processes, &(&1.process_id == process_id)) do
          nil -> {:error, :not_found}
          process_data -> {:ok, process_data}
        end
      process_data -> {:ok, process_data}
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_aggregated_metrics, time_range}, _from, state) do
    filtered_processes = filter_processes_by_time_range(state.completed_processes, time_range)
    aggregated = calculate_aggregated_metrics(filtered_processes)
    {:reply, {:ok, aggregated}, state}
  end

  @impl true
  def handle_call(:get_improvement_statistics, _from, state) do
    stats = calculate_improvement_statistics(state.completed_processes)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call({:export_metrics, format, time_range}, _from, state) do
    filtered_processes = filter_processes_by_time_range(state.completed_processes, time_range)

    result = case format do
      :json -> export_as_json(filtered_processes, state.aggregated_stats)
      :csv -> export_as_csv(filtered_processes)
      _ -> {:error, "Unsupported export format: #{format}"}
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:cleanup_metrics, retention_days}, _from, state) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-retention_days * 24 * 60 * 60, :second)

    {kept_processes, removed_processes} = Enum.split_with(state.completed_processes, fn process ->
      DateTime.compare(process.completed_at, cutoff_date) == :gt
    end)

    cleared_count = length(removed_processes)
    new_state = %{state | completed_processes: kept_processes}

    # Recalculate aggregated stats
    new_aggregated = calculate_aggregated_metrics(kept_processes)
    final_state = %{new_state | aggregated_stats: new_aggregated}

    # Persist updated metrics
    save_metrics_to_storage(final_state, state.metrics_file_path)

    Logger.info("Cleaned up #{cleared_count} old reflection metrics records")
    {:reply, {:ok, cleared_count}, final_state}
  end

  # Private Functions

  defp initialize_aggregated_stats() do
    %{
      total_processes: 0,
      successful_processes: 0,
      failed_processes: 0,
      average_quality_improvement: 0.0,
      average_processing_time_ms: 0.0,
      average_iterations: 0.0,
      quality_distribution: %{
        excellent: 0,  # > 0.9
        good: 0,       # 0.7-0.9
        fair: 0,       # 0.5-0.7
        poor: 0        # < 0.5
      },
      last_updated: DateTime.utc_now()
    }
  end

  defp calculate_improvement_metrics(process_data) do
    iterations = Enum.sort_by(process_data.iterations, & &1.iteration)

    case {List.first(iterations), List.last(iterations)} do
      {nil, _} -> %{quality_delta: 0.0, improvement_percentage: 0.0}
      {first, last} when first == last -> %{quality_delta: 0.0, improvement_percentage: 0.0}
      {first, last} ->
        initial_quality = get_overall_quality_score(first.quality_scores)
        final_quality = get_overall_quality_score(last.quality_scores)

        quality_delta = final_quality - initial_quality
        improvement_percentage = if initial_quality > 0, do: (quality_delta / initial_quality) * 100, else: 0.0

        %{
          quality_delta: quality_delta,
          improvement_percentage: improvement_percentage,
          initial_quality: initial_quality,
          final_quality: final_quality,
          iterations_performed: length(iterations) - 1
        }
    end
  end

  defp get_overall_quality_score(quality_scores) do
    Map.get(quality_scores, :overall, 0.0)
  end

  defp update_aggregated_stats(current_stats, completed_process) do
    total = current_stats.total_processes + 1
    successful = if completed_process.success, do: current_stats.successful_processes + 1, else: current_stats.successful_processes
    failed = if not completed_process.success, do: current_stats.failed_processes + 1, else: current_stats.failed_processes

    # Calculate running averages
    improvement = Map.get(completed_process.improvement_metrics, :improvement_percentage, 0.0)
    processing_time = Map.get(completed_process.performance_metrics, :processing_time_ms, 0.0)
    iterations = Map.get(completed_process.improvement_metrics, :iterations_performed, 0)

    avg_improvement = calculate_running_average(current_stats.average_quality_improvement, improvement, total)
    avg_time = calculate_running_average(current_stats.average_processing_time_ms, processing_time, total)
    avg_iterations = calculate_running_average(current_stats.average_iterations, iterations, total)

    # Update quality distribution
    final_quality = Map.get(completed_process.improvement_metrics, :final_quality, 0.0)
    quality_dist = update_quality_distribution(current_stats.quality_distribution, final_quality)

    %{current_stats |
      total_processes: total,
      successful_processes: successful,
      failed_processes: failed,
      average_quality_improvement: avg_improvement,
      average_processing_time_ms: avg_time,
      average_iterations: avg_iterations,
      quality_distribution: quality_dist,
      last_updated: DateTime.utc_now()
    }
  end

  defp calculate_running_average(current_avg, new_value, count) do
    ((current_avg * (count - 1)) + new_value) / count
  end

  defp update_quality_distribution(dist, quality_score) do
    cond do
      quality_score > 0.9 -> %{dist | excellent: dist.excellent + 1}
      quality_score >= 0.7 -> %{dist | good: dist.good + 1}
      quality_score >= 0.5 -> %{dist | fair: dist.fair + 1}
      true -> %{dist | poor: dist.poor + 1}
    end
  end

  defp filter_processes_by_time_range(processes, :all), do: processes
  defp filter_processes_by_time_range(processes, time_range) do
    cutoff = case time_range do
      :last_hour -> DateTime.utc_now() |> DateTime.add(-1, :hour)
      :last_day -> DateTime.utc_now() |> DateTime.add(-1, :day)
      :last_week -> DateTime.utc_now() |> DateTime.add(-7, :day)
      _ -> DateTime.utc_now() |> DateTime.add(-1, :day)  # Default to last day
    end

    Enum.filter(processes, fn process ->
      DateTime.compare(process.completed_at, cutoff) == :gt
    end)
  end

  defp calculate_aggregated_metrics(processes) do
    if Enum.empty?(processes) do
      initialize_aggregated_stats()
    else
      total_count = length(processes)
      successful_count = Enum.count(processes, & &1.success)

      improvements = Enum.map(processes, &Map.get(&1.improvement_metrics, :improvement_percentage, 0.0))
      times = Enum.map(processes, &Map.get(&1.performance_metrics, :processing_time_ms, 0.0))
      iterations = Enum.map(processes, &Map.get(&1.improvement_metrics, :iterations_performed, 0))

      %{
        total_processes: total_count,
        successful_processes: successful_count,
        failed_processes: total_count - successful_count,
        average_quality_improvement: Enum.sum(improvements) / total_count,
        average_processing_time_ms: Enum.sum(times) / total_count,
        average_iterations: Enum.sum(iterations) / total_count,
        success_rate: successful_count / total_count,
        last_updated: DateTime.utc_now()
      }
    end
  end

  defp calculate_improvement_statistics(processes) do
    successful_processes = Enum.filter(processes, & &1.success)

    if Enum.empty?(successful_processes) do
      %{
        total_analyzed: 0,
        processes_improved: 0,
        improvement_rate: 0.0,
        average_improvement: 0.0,
        max_improvement: 0.0,
        min_improvement: 0.0
      }
    else
      improvements = Enum.map(successful_processes, &Map.get(&1.improvement_metrics, :improvement_percentage, 0.0))
      improved_count = Enum.count(improvements, &(&1 > 0))

      %{
        total_analyzed: length(successful_processes),
        processes_improved: improved_count,
        improvement_rate: improved_count / length(successful_processes),
        average_improvement: Enum.sum(improvements) / length(improvements),
        max_improvement: Enum.max(improvements),
        min_improvement: Enum.min(improvements),
        improvement_distribution: calculate_improvement_distribution(improvements)
      }
    end
  end

  defp calculate_improvement_distribution(improvements) do
    %{
      significant: Enum.count(improvements, &(&1 > 20)),      # > 20% improvement
      moderate: Enum.count(improvements, &(&1 > 10 and &1 <= 20)),  # 10-20% improvement
      minor: Enum.count(improvements, &(&1 > 0 and &1 <= 10)),      # 0-10% improvement
      no_change: Enum.count(improvements, &(&1 == 0)),              # No improvement
      degraded: Enum.count(improvements, &(&1 < 0))                 # Quality decreased
    }
  end

  defp export_as_json(processes, aggregated_stats) do
    export_data = %{
      metadata: %{
        exported_at: DateTime.utc_now(),
        version: @metrics_version,
        process_count: length(processes)
      },
      aggregated_statistics: aggregated_stats,
      processes: processes
    }

    case Jason.encode(export_data, pretty: true) do
      {:ok, json_string} -> {:ok, json_string}
      {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
    end
  end

  defp export_as_csv(processes) do
    headers = [
      "process_id", "started_at", "completed_at", "success", "iterations_performed",
      "initial_quality", "final_quality", "quality_improvement", "processing_time_ms"
    ]

    rows = Enum.map(processes, fn process ->
      improvement = process.improvement_metrics
      performance = process.performance_metrics

      [
        process.process_id,
        DateTime.to_iso8601(process.started_at),
        DateTime.to_iso8601(process.completed_at),
        process.success,
        Map.get(improvement, :iterations_performed, 0),
        Map.get(improvement, :initial_quality, 0.0),
        Map.get(improvement, :final_quality, 0.0),
        Map.get(improvement, :improvement_percentage, 0.0),
        Map.get(performance, :processing_time_ms, 0.0)
      ]
    end)

    csv_content = [headers | rows]
    |> Enum.map(&Enum.join(&1, ","))
    |> Enum.join("\n")

    {:ok, csv_content}
  end

  defp get_metrics_file_path() do
    Path.join([Application.app_dir(:decision_engine, "priv"), "reflection_metrics.json"])
  end

  defp save_metrics_to_storage(state, file_path) do
    try do
      # Prepare data for storage (limit completed processes to prevent file bloat)
      recent_processes = state.completed_processes |> Enum.take(1000)  # Keep last 1000 processes

      storage_data = %{
        completed_processes: recent_processes,
        aggregated_stats: state.aggregated_stats,
        version: @metrics_version,
        saved_at: DateTime.utc_now()
      }

      # Ensure directory exists
      file_path |> Path.dirname() |> File.mkdir_p!()

      case Jason.encode(storage_data, pretty: true) do
        {:ok, json_string} ->
          File.write(file_path, json_string)
        {:error, reason} ->
          Logger.error("Failed to encode reflection metrics: #{inspect(reason)}")
      end
    rescue
      error ->
        Logger.error("Exception saving reflection metrics: #{inspect(error)}")
    end
  end

  defp load_metrics_from_storage(file_path) do
    try do
      case File.read(file_path) do
        {:ok, json_string} ->
          case Jason.decode(json_string, keys: :atoms) do
            {:ok, data} ->
              # Convert datetime strings back to DateTime structs
              converted_data = convert_datetime_strings(data)
              {:ok, converted_data}
            {:error, reason} ->
              {:error, "Failed to parse metrics file: #{inspect(reason)}"}
          end
        {:error, :enoent} ->
          {:error, "No metrics file found"}
        {:error, reason} ->
          {:error, "Failed to read metrics file: #{inspect(reason)}"}
      end
    rescue
      error ->
        {:error, "Exception loading metrics: #{inspect(error)}"}
    end
  end

  defp convert_datetime_strings(data) when is_map(data) do
    data
    |> Enum.map(fn
      {key, value} when key in [:started_at, :completed_at, :timestamp, :last_updated, :saved_at] and is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> {key, dt}
          _ -> {key, value}
        end
      {key, value} when is_map(value) -> {key, convert_datetime_strings(value)}
      {key, value} when is_list(value) -> {key, Enum.map(value, &convert_datetime_strings/1)}
      {key, value} -> {key, value}
    end)
    |> Map.new()
  end
  defp convert_datetime_strings(data) when is_list(data) do
    Enum.map(data, &convert_datetime_strings/1)
  end
  defp convert_datetime_strings(data), do: data
end
