defmodule DecisionEngine.ReqLLMAgentPerformanceTracker do
  @moduledoc """
  Tracks and analyzes performance metrics for agentic workflows.

  This module provides comprehensive performance tracking for agents, including
  conversation quality metrics, agent performance monitoring, optimization
  suggestions, and feedback systems for continuous improvement.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger
  alias DecisionEngine.ReqLLMCorrelation
  alias DecisionEngine.ReqLLMAgentConversationManager

  @type performance_metric :: %{
    metric_name: String.t(),
    value: float(),
    unit: String.t(),
    timestamp: DateTime.t(),
    context: map()
  }

  @type agent_performance :: %{
    agent_id: String.t(),
    agent_type: atom(),
    metrics: [performance_metric()],
    aggregated_metrics: map(),
    performance_score: float(),
    last_updated: DateTime.t(),
    tracking_period: map()
  }

  @type conversation_quality :: %{
    conversation_id: String.t(),
    quality_score: float(),
    metrics: map(),
    feedback: [map()],
    analyzed_at: DateTime.t()
  }

  @type performance_feedback :: %{
    id: String.t(),
    agent_id: String.t(),
    feedback_type: atom(),
    recommendations: [String.t()],
    priority: atom(),
    created_at: DateTime.t(),
    status: atom()
  }

  @doc """
  Starts performance tracking for an agent.

  ## Parameters
  - agent_id: Unique identifier for the agent
  - agent_type: Type of agent being tracked
  - tracking_config: Configuration for performance tracking

  ## Returns
  - :ok on successful start
  - {:error, reason} if tracking setup fails
  """
  @spec start_tracking(String.t(), atom(), map()) :: :ok | {:error, term()}
  def start_tracking(agent_id, agent_type, tracking_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, performance_record} <- initialize_performance_record(agent_id, agent_type, tracking_config),
         :ok <- store_performance_record(performance_record),
         :ok <- setup_metric_collection(agent_id, tracking_config) do

      ReqLLMLogger.log_agent_event(:performance_tracking_started, %{
        agent_id: agent_id,
        agent_type: agent_type,
        tracking_config: tracking_config
      }, %{correlation_id: correlation_id})

      :ok
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:performance_tracking_start_failed, %{
          agent_id: agent_id,
          agent_type: agent_type,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Records a performance metric for an agent.

  ## Parameters
  - agent_id: ID of the agent
  - metric_name: Name of the metric
  - value: Metric value
  - unit: Unit of measurement
  - context: Additional context information

  ## Returns
  - :ok on successful recording
  - {:error, reason} if recording fails
  """
  @spec record_metric(String.t(), String.t(), float(), String.t(), map()) :: :ok | {:error, term()}
  def record_metric(agent_id, metric_name, value, unit \\ "", context \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, performance_record} <- get_performance_record(agent_id),
         {:ok, metric} <- create_performance_metric(metric_name, value, unit, context),
         {:ok, updated_record} <- add_metric_to_record(performance_record, metric),
         :ok <- store_performance_record(updated_record),
         :ok <- update_aggregated_metrics(agent_id, metric) do

      ReqLLMLogger.log_agent_event(:metric_recorded, %{
        agent_id: agent_id,
        metric_name: metric_name,
        value: value,
        unit: unit
      }, %{correlation_id: correlation_id})

      :ok
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:metric_recording_failed, %{
          agent_id: agent_id,
          metric_name: metric_name,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Analyzes conversation quality for an agent conversation.

  ## Parameters
  - conversation_id: ID of the conversation to analyze
  - analysis_config: Configuration for quality analysis

  ## Returns
  - {:ok, conversation_quality} on successful analysis
  - {:error, reason} if analysis fails
  """
  @spec analyze_conversation_quality(String.t(), map()) :: {:ok, conversation_quality()} | {:error, term()}
  def analyze_conversation_quality(conversation_id, analysis_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, conversation} <- ReqLLMAgentConversationManager.get_conversation(conversation_id),
         {:ok, quality_metrics} <- calculate_quality_metrics(conversation, analysis_config),
         {:ok, quality_score} <- calculate_overall_quality_score(quality_metrics),
         {:ok, feedback} <- generate_quality_feedback(quality_metrics, conversation),
         {:ok, quality_analysis} <- create_quality_analysis(conversation_id, quality_score, quality_metrics, feedback),
         :ok <- store_quality_analysis(quality_analysis),
         :ok <- update_agent_quality_metrics(conversation.agent_id, quality_analysis) do

      ReqLLMLogger.log_agent_event(:conversation_quality_analyzed, %{
        conversation_id: conversation_id,
        agent_id: conversation.agent_id,
        quality_score: quality_score,
        metrics_count: map_size(quality_metrics)
      }, %{correlation_id: correlation_id})

      {:ok, quality_analysis}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:conversation_quality_analysis_failed, %{
          conversation_id: conversation_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Gets current performance metrics for an agent.

  ## Parameters
  - agent_id: ID of the agent
  - time_range: Optional time range for metrics

  ## Returns
  - {:ok, agent_performance} current performance data
  - {:error, reason} if retrieval fails
  """
  @spec get_agent_performance(String.t(), map()) :: {:ok, agent_performance()} | {:error, term()}
  def get_agent_performance(agent_id, time_range \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, performance_record} <- get_performance_record(agent_id),
         {:ok, filtered_metrics} <- filter_metrics_by_time_range(performance_record.metrics, time_range),
         {:ok, current_aggregated} <- calculate_current_aggregated_metrics(filtered_metrics),
         {:ok, performance_score} <- calculate_performance_score(current_aggregated) do

      current_performance = %{performance_record |
        metrics: filtered_metrics,
        aggregated_metrics: current_aggregated,
        performance_score: performance_score,
        last_updated: DateTime.utc_now()
      }

      ReqLLMLogger.log_agent_event(:performance_retrieved, %{
        agent_id: agent_id,
        performance_score: performance_score,
        metrics_count: length(filtered_metrics)
      }, %{correlation_id: correlation_id})

      {:ok, current_performance}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:performance_retrieval_failed, %{
          agent_id: agent_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Generates performance feedback and recommendations for an agent.

  ## Parameters
  - agent_id: ID of the agent
  - feedback_config: Configuration for feedback generation

  ## Returns
  - {:ok, performance_feedback} generated feedback
  - {:error, reason} if feedback generation fails
  """
  @spec generate_performance_feedback(String.t(), map()) :: {:ok, performance_feedback()} | {:error, term()}
  def generate_performance_feedback(agent_id, feedback_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, performance_record} <- get_performance_record(agent_id),
         {:ok, performance_analysis} <- analyze_performance_trends(performance_record),
         {:ok, recommendations} <- generate_recommendations(performance_analysis, feedback_config),
         {:ok, feedback_priority} <- determine_feedback_priority(performance_analysis),
         {:ok, feedback} <- create_performance_feedback(agent_id, recommendations, feedback_priority),
         :ok <- store_performance_feedback(feedback) do

      ReqLLMLogger.log_agent_event(:performance_feedback_generated, %{
        agent_id: agent_id,
        feedback_id: feedback.id,
        recommendations_count: length(recommendations),
        priority: feedback_priority
      }, %{correlation_id: correlation_id})

      {:ok, feedback}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:performance_feedback_generation_failed, %{
          agent_id: agent_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Monitors agent performance and triggers alerts if needed.

  ## Parameters
  - agent_id: ID of the agent to monitor
  - monitoring_config: Configuration for monitoring thresholds

  ## Returns
  - {:ok, monitoring_result} monitoring results
  - {:error, reason} if monitoring fails
  """
  @spec monitor_agent_performance(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def monitor_agent_performance(agent_id, monitoring_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, performance_record} <- get_performance_record(agent_id),
         {:ok, current_metrics} <- get_recent_metrics(performance_record, monitoring_config),
         {:ok, threshold_violations} <- check_performance_thresholds(current_metrics, monitoring_config),
         {:ok, monitoring_result} <- create_monitoring_result(agent_id, current_metrics, threshold_violations),
         :ok <- handle_threshold_violations(agent_id, threshold_violations) do

      ReqLLMLogger.log_agent_event(:performance_monitored, %{
        agent_id: agent_id,
        violations_count: length(threshold_violations),
        monitoring_result: monitoring_result
      }, %{correlation_id: correlation_id})

      {:ok, monitoring_result}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:performance_monitoring_failed, %{
          agent_id: agent_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Gets performance comparison between multiple agents.

  ## Parameters
  - agent_ids: List of agent IDs to compare
  - comparison_config: Configuration for comparison

  ## Returns
  - {:ok, comparison_results} comparison data
  - {:error, reason} if comparison fails
  """
  @spec compare_agent_performance([String.t()], map()) :: {:ok, map()} | {:error, term()}
  def compare_agent_performance(agent_ids, comparison_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    try do
      performance_data = Enum.map(agent_ids, fn agent_id ->
        case get_agent_performance(agent_id, comparison_config) do
          {:ok, performance} -> {agent_id, performance}
          {:error, _} -> {agent_id, nil}
        end
      end)

      valid_performances = Enum.filter(performance_data, fn {_id, perf} -> not is_nil(perf) end)

      comparison_results = %{
        agents_compared: length(valid_performances),
        performance_rankings: rank_agents_by_performance(valid_performances),
        metric_comparisons: compare_metrics_across_agents(valid_performances),
        insights: generate_comparison_insights(valid_performances),
        compared_at: DateTime.utc_now()
      }

      ReqLLMLogger.log_agent_event(:agents_performance_compared, %{
        agent_ids: agent_ids,
        valid_agents: length(valid_performances),
        comparison_results: comparison_results
      }, %{correlation_id: correlation_id})

      {:ok, comparison_results}
    rescue
      error ->
        ReqLLMLogger.log_agent_event(:agent_performance_comparison_failed, %{
          agent_ids: agent_ids,
          error: inspect(error)
        }, %{correlation_id: correlation_id})
        {:error, error}
    end
  end

  # Private Functions

  defp initialize_performance_record(agent_id, agent_type, tracking_config) do
    performance_record = %{
      agent_id: agent_id,
      agent_type: agent_type,
      metrics: [],
      aggregated_metrics: %{},
      performance_score: 0.0,
      last_updated: DateTime.utc_now(),
      tracking_period: %{
        start_date: DateTime.utc_now(),
        end_date: Map.get(tracking_config, :end_date),
        collection_interval: Map.get(tracking_config, :collection_interval, 300) # 5 minutes
      },
      config: tracking_config
    }

    {:ok, performance_record}
  end

  defp store_performance_record(performance_record) do
    table_name = :req_llm_agent_performance

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {performance_record.agent_id, performance_record})
    :ok
  end

  defp get_performance_record(agent_id) do
    table_name = :req_llm_agent_performance

    case :ets.lookup(table_name, agent_id) do
      [{^agent_id, performance_record}] ->
        {:ok, performance_record}
      [] ->
        {:error, "Performance record not found for agent: #{agent_id}"}
    end
  end

  defp setup_metric_collection(agent_id, tracking_config) do
    # Set up periodic metric collection if configured
    collection_interval = Map.get(tracking_config, :collection_interval, 300) * 1000 # Convert to ms

    if Map.get(tracking_config, :auto_collect, false) do
      spawn(fn ->
        metric_collection_loop(agent_id, collection_interval)
      end)
    end

    :ok
  end

  defp metric_collection_loop(agent_id, interval) do
    Process.sleep(interval)

    # Collect automatic metrics
    collect_automatic_metrics(agent_id)

    # Continue loop
    metric_collection_loop(agent_id, interval)
  end

  defp collect_automatic_metrics(agent_id) do
    # Collect system metrics
    memory_usage = :erlang.memory(:total) / (1024 * 1024) # MB
    process_count = length(Process.list())

    record_metric(agent_id, "system_memory_mb", memory_usage, "MB", %{auto_collected: true})
    record_metric(agent_id, "system_processes", process_count, "count", %{auto_collected: true})

    # Collect conversation metrics if available
    case ReqLLMAgentConversationManager.list_conversations(agent_id, %{status: :active}) do
      {:ok, conversations} ->
        active_conversations = length(conversations)
        record_metric(agent_id, "active_conversations", active_conversations, "count", %{auto_collected: true})
      _ ->
        :ok
    end
  end

  defp create_performance_metric(metric_name, value, unit, context) do
    metric = %{
      metric_name: metric_name,
      value: value,
      unit: unit,
      timestamp: DateTime.utc_now(),
      context: context
    }

    {:ok, metric}
  end

  defp add_metric_to_record(performance_record, metric) do
    # Add metric and maintain a reasonable history size
    max_metrics = 1000
    updated_metrics = [metric | performance_record.metrics]

    trimmed_metrics = if length(updated_metrics) > max_metrics do
      Enum.take(updated_metrics, max_metrics)
    else
      updated_metrics
    end

    updated_record = %{performance_record |
      metrics: trimmed_metrics,
      last_updated: DateTime.utc_now()
    }

    {:ok, updated_record}
  end

  defp update_aggregated_metrics(agent_id, new_metric) do
    case get_performance_record(agent_id) do
      {:ok, performance_record} ->
        updated_aggregated = calculate_updated_aggregated_metrics(performance_record.aggregated_metrics, new_metric)
        updated_record = %{performance_record | aggregated_metrics: updated_aggregated}
        store_performance_record(updated_record)

      {:error, _} ->
        :ok # Record doesn't exist yet, will be created later
    end
  end

  defp calculate_updated_aggregated_metrics(current_aggregated, new_metric) do
    metric_key = new_metric.metric_name

    current_stats = Map.get(current_aggregated, metric_key, %{
      count: 0,
      sum: 0.0,
      avg: 0.0,
      min: nil,
      max: nil,
      last_value: nil
    })

    updated_stats = %{
      count: current_stats.count + 1,
      sum: current_stats.sum + new_metric.value,
      avg: (current_stats.sum + new_metric.value) / (current_stats.count + 1),
      min: if(is_nil(current_stats.min), do: new_metric.value, else: min(current_stats.min, new_metric.value)),
      max: if(is_nil(current_stats.max), do: new_metric.value, else: max(current_stats.max, new_metric.value)),
      last_value: new_metric.value,
      last_updated: new_metric.timestamp
    }

    Map.put(current_aggregated, metric_key, updated_stats)
  end

  defp calculate_quality_metrics(conversation, analysis_config) do
    metrics = %{}

    # Message count and distribution
    message_count = length(conversation.messages)
    user_messages = Enum.count(conversation.messages, fn m -> m.role == :user end)
    assistant_messages = Enum.count(conversation.messages, fn m -> m.role == :assistant end)

    metrics = Map.merge(metrics, %{
      message_count: message_count,
      user_messages: user_messages,
      assistant_messages: assistant_messages,
      message_balance: if(user_messages > 0, do: assistant_messages / user_messages, else: 0.0)
    })

    # Response length analysis
    assistant_responses = Enum.filter(conversation.messages, fn m -> m.role == :assistant end)
    response_lengths = Enum.map(assistant_responses, fn m -> String.length(m.content) end)

    metrics = if length(response_lengths) > 0 do
      Map.merge(metrics, %{
        avg_response_length: Enum.sum(response_lengths) / length(response_lengths),
        min_response_length: Enum.min(response_lengths),
        max_response_length: Enum.max(response_lengths)
      })
    else
      metrics
    end

    # Conversation duration
    if message_count > 0 do
      first_message = List.first(conversation.messages)
      last_message = List.last(conversation.messages)
      duration_minutes = DateTime.diff(last_message.timestamp, first_message.timestamp, :minute)

      metrics = Map.put(metrics, :conversation_duration_minutes, duration_minutes)
    end

    # Custom metrics based on analysis config
    custom_metrics = Map.get(analysis_config, :custom_metrics, [])
    metrics = Enum.reduce(custom_metrics, metrics, fn custom_metric, acc ->
      case calculate_custom_metric(conversation, custom_metric) do
        {:ok, value} -> Map.put(acc, custom_metric.name, value)
        _ -> acc
      end
    end)

    {:ok, metrics}
  end

  defp calculate_custom_metric(conversation, custom_metric) do
    # Placeholder for custom metric calculation
    case custom_metric.type do
      :keyword_frequency ->
        keyword = custom_metric.keyword
        total_content = Enum.map_join(conversation.messages, " ", fn m -> m.content end)
        frequency = length(Regex.scan(~r/#{keyword}/i, total_content))
        {:ok, frequency}

      _ ->
        {:error, "Unknown custom metric type"}
    end
  end

  defp calculate_overall_quality_score(quality_metrics) do
    # Simple quality score calculation
    score = 0.0

    # Message balance contributes to quality
    message_balance = Map.get(quality_metrics, :message_balance, 0.0)
    balance_score = min(1.0, message_balance) * 0.3

    # Response length consistency
    avg_length = Map.get(quality_metrics, :avg_response_length, 0)
    length_score = cond do
      avg_length >= 100 and avg_length <= 500 -> 0.3
      avg_length > 50 -> 0.2
      true -> 0.1
    end

    # Conversation engagement (more messages = better engagement)
    message_count = Map.get(quality_metrics, :message_count, 0)
    engagement_score = min(0.4, message_count * 0.05)

    total_score = balance_score + length_score + engagement_score
    {:ok, min(1.0, total_score)}
  end

  defp generate_quality_feedback(quality_metrics, conversation) do
    feedback = []

    # Check message balance
    message_balance = Map.get(quality_metrics, :message_balance, 0.0)
    feedback = if message_balance < 0.5 do
      [%{
        type: :improvement,
        message: "Consider encouraging more user interaction",
        priority: :medium
      } | feedback]
    else
      feedback
    end

    # Check response length
    avg_length = Map.get(quality_metrics, :avg_response_length, 0)
    feedback = cond do
      avg_length < 50 ->
        [%{
          type: :improvement,
          message: "Responses are quite short, consider providing more detailed answers",
          priority: :low
        } | feedback]

      avg_length > 1000 ->
        [%{
          type: :improvement,
          message: "Responses are quite long, consider being more concise",
          priority: :medium
        } | feedback]

      true ->
        feedback
    end

    # Check conversation duration
    duration = Map.get(quality_metrics, :conversation_duration_minutes, 0)
    feedback = if duration > 60 do
      [%{
        type: :observation,
        message: "Long conversation detected, monitor for user fatigue",
        priority: :low
      } | feedback]
    else
      feedback
    end

    {:ok, feedback}
  end

  defp create_quality_analysis(conversation_id, quality_score, quality_metrics, feedback) do
    quality_analysis = %{
      conversation_id: conversation_id,
      quality_score: quality_score,
      metrics: quality_metrics,
      feedback: feedback,
      analyzed_at: DateTime.utc_now()
    }

    {:ok, quality_analysis}
  end

  defp store_quality_analysis(quality_analysis) do
    table_name = :req_llm_conversation_quality

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {quality_analysis.conversation_id, quality_analysis})
    :ok
  end

  defp update_agent_quality_metrics(agent_id, quality_analysis) do
    # Update agent's overall quality metrics
    quality_metric = %{
      metric_name: "conversation_quality_score",
      value: quality_analysis.quality_score,
      unit: "score",
      timestamp: DateTime.utc_now(),
      context: %{
        conversation_id: quality_analysis.conversation_id,
        feedback_count: length(quality_analysis.feedback)
      }
    }

    record_metric(agent_id, quality_metric.metric_name, quality_metric.value, quality_metric.unit, quality_metric.context)
  end

  defp filter_metrics_by_time_range(metrics, time_range) do
    case {Map.get(time_range, :start_date), Map.get(time_range, :end_date)} do
      {nil, nil} ->
        {:ok, metrics}

      {start_date, nil} ->
        filtered = Enum.filter(metrics, fn metric ->
          DateTime.compare(metric.timestamp, start_date) != :lt
        end)
        {:ok, filtered}

      {nil, end_date} ->
        filtered = Enum.filter(metrics, fn metric ->
          DateTime.compare(metric.timestamp, end_date) != :gt
        end)
        {:ok, filtered}

      {start_date, end_date} ->
        filtered = Enum.filter(metrics, fn metric ->
          DateTime.compare(metric.timestamp, start_date) != :lt and
          DateTime.compare(metric.timestamp, end_date) != :gt
        end)
        {:ok, filtered}
    end
  end

  defp calculate_current_aggregated_metrics(metrics) do
    aggregated = Enum.group_by(metrics, fn metric -> metric.metric_name end)
    |> Enum.map(fn {metric_name, metric_list} ->
      values = Enum.map(metric_list, fn m -> m.value end)

      stats = %{
        count: length(values),
        sum: Enum.sum(values),
        avg: if(length(values) > 0, do: Enum.sum(values) / length(values), else: 0.0),
        min: if(length(values) > 0, do: Enum.min(values), else: nil),
        max: if(length(values) > 0, do: Enum.max(values), else: nil),
        last_value: if(length(values) > 0, do: List.first(metric_list).value, else: nil)
      }

      {metric_name, stats}
    end)
    |> Enum.into(%{})

    {:ok, aggregated}
  end

  defp calculate_performance_score(aggregated_metrics) do
    # Calculate overall performance score based on key metrics
    score = 0.0

    # Quality score contribution
    quality_stats = Map.get(aggregated_metrics, "conversation_quality_score")
    score = if quality_stats do
      score + (quality_stats.avg * 0.4)
    else
      score
    end

    # Response time contribution (lower is better)
    response_time_stats = Map.get(aggregated_metrics, "response_time_ms")
    score = if response_time_stats do
      # Normalize response time (assume 3000ms is baseline)
      normalized_time = max(0.0, 1.0 - (response_time_stats.avg / 3000.0))
      score + (normalized_time * 0.3)
    else
      score + 0.3 # Default if no response time data
    end

    # Success rate contribution
    success_rate_stats = Map.get(aggregated_metrics, "success_rate")
    score = if success_rate_stats do
      score + (success_rate_stats.avg * 0.3)
    else
      score + 0.3 # Default if no success rate data
    end

    {:ok, min(1.0, score)}
  end

  defp analyze_performance_trends(performance_record) do
    # Analyze trends in performance metrics
    recent_metrics = Enum.take(performance_record.metrics, 100) # Last 100 metrics

    trends = %{
      quality_trend: analyze_metric_trend(recent_metrics, "conversation_quality_score"),
      response_time_trend: analyze_metric_trend(recent_metrics, "response_time_ms"),
      success_rate_trend: analyze_metric_trend(recent_metrics, "success_rate"),
      overall_performance_trend: :stable
    }

    # Determine overall trend
    trend_values = [trends.quality_trend, trends.response_time_trend, trends.success_rate_trend]
    improving_count = Enum.count(trend_values, fn t -> t == :improving end)
    declining_count = Enum.count(trend_values, fn t -> t == :declining end)

    overall_trend = cond do
      improving_count > declining_count -> :improving
      declining_count > improving_count -> :declining
      true -> :stable
    end

    analysis = %{trends | overall_performance_trend: overall_trend}
    {:ok, analysis}
  end

  defp analyze_metric_trend(metrics, metric_name) do
    metric_values = metrics
    |> Enum.filter(fn m -> m.metric_name == metric_name end)
    |> Enum.map(fn m -> m.value end)
    |> Enum.reverse() # Chronological order

    case length(metric_values) do
      n when n < 3 -> :insufficient_data
      _ ->
        first_half = Enum.take(metric_values, div(length(metric_values), 2))
        second_half = Enum.drop(metric_values, div(length(metric_values), 2))

        first_avg = Enum.sum(first_half) / length(first_half)
        second_avg = Enum.sum(second_half) / length(second_half)

        change_percent = (second_avg - first_avg) / first_avg * 100

        cond do
          change_percent > 5 -> :improving
          change_percent < -5 -> :declining
          true -> :stable
        end
    end
  end

  defp generate_recommendations(performance_analysis, _feedback_config) do
    recommendations = []

    # Quality recommendations
    recommendations = case performance_analysis.trends.quality_trend do
      :declining ->
        ["Review conversation templates for clarity", "Analyze recent conversation feedback" | recommendations]
      :stable ->
        ["Consider A/B testing new conversation approaches" | recommendations]
      _ ->
        recommendations
    end

    # Response time recommendations
    recommendations = case performance_analysis.trends.response_time_trend do
      :declining ->
        ["Optimize prompt templates for faster processing", "Review LLM configuration settings" | recommendations]
      _ ->
        recommendations
    end

    # Success rate recommendations
    recommendations = case performance_analysis.trends.success_rate_trend do
      :declining ->
        ["Review error patterns and improve error handling", "Update validation rules" | recommendations]
      _ ->
        recommendations
    end

    {:ok, recommendations}
  end

  defp determine_feedback_priority(performance_analysis) do
    case performance_analysis.trends.overall_performance_trend do
      :declining -> {:ok, :high}
      :stable -> {:ok, :medium}
      :improving -> {:ok, :low}
      _ -> {:ok, :medium}
    end
  end

  defp create_performance_feedback(agent_id, recommendations, priority) do
    feedback = %{
      id: generate_feedback_id(),
      agent_id: agent_id,
      feedback_type: :performance_optimization,
      recommendations: recommendations,
      priority: priority,
      created_at: DateTime.utc_now(),
      status: :pending
    }

    {:ok, feedback}
  end

  defp generate_feedback_id do
    :crypto.strong_rand_bytes(12) |> Base.encode64(padding: false)
  end

  defp store_performance_feedback(feedback) do
    table_name = :req_llm_performance_feedback

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :bag, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {feedback.agent_id, feedback})
    :ok
  end

  defp get_recent_metrics(performance_record, monitoring_config) do
    lookback_minutes = Map.get(monitoring_config, :lookback_minutes, 30)
    cutoff_time = DateTime.add(DateTime.utc_now(), -lookback_minutes, :minute)

    recent_metrics = Enum.filter(performance_record.metrics, fn metric ->
      DateTime.compare(metric.timestamp, cutoff_time) != :lt
    end)

    {:ok, recent_metrics}
  end

  defp check_performance_thresholds(metrics, monitoring_config) do
    thresholds = Map.get(monitoring_config, :thresholds, %{})
    violations = []

    # Check each threshold
    violations = Enum.reduce(thresholds, violations, fn {metric_name, threshold_config}, acc ->
      metric_values = metrics
      |> Enum.filter(fn m -> m.metric_name == metric_name end)
      |> Enum.map(fn m -> m.value end)

      if length(metric_values) > 0 do
        current_value = List.first(metric_values)

        violation = case threshold_config do
          %{max: max_val} when current_value > max_val ->
            %{
              metric: metric_name,
              type: :max_exceeded,
              current_value: current_value,
              threshold: max_val,
              severity: Map.get(threshold_config, :severity, :medium)
            }

          %{min: min_val} when current_value < min_val ->
            %{
              metric: metric_name,
              type: :min_not_met,
              current_value: current_value,
              threshold: min_val,
              severity: Map.get(threshold_config, :severity, :medium)
            }

          _ ->
            nil
        end

        if violation, do: [violation | acc], else: acc
      else
        acc
      end
    end)

    {:ok, violations}
  end

  defp create_monitoring_result(agent_id, current_metrics, threshold_violations) do
    result = %{
      agent_id: agent_id,
      monitored_at: DateTime.utc_now(),
      metrics_count: length(current_metrics),
      violations: threshold_violations,
      status: if(length(threshold_violations) > 0, do: :alert, else: :normal),
      summary: create_monitoring_summary(current_metrics, threshold_violations)
    }

    {:ok, result}
  end

  defp create_monitoring_summary(metrics, violations) do
    %{
      total_metrics: length(metrics),
      violations_count: length(violations),
      high_severity_violations: Enum.count(violations, fn v -> v.severity == :high end),
      unique_metrics: length(Enum.uniq_by(metrics, fn m -> m.metric_name end))
    }
  end

  defp handle_threshold_violations(agent_id, violations) do
    # Handle violations based on severity
    high_severity = Enum.filter(violations, fn v -> v.severity == :high end)

    if length(high_severity) > 0 do
      Logger.warning("High severity performance violations for agent #{agent_id}: #{inspect(high_severity)}")

      # Could trigger alerts, notifications, etc.
      ReqLLMLogger.log_agent_event(:performance_alert, %{
        agent_id: agent_id,
        violations: high_severity
      }, %{})
    end

    :ok
  end

  defp rank_agents_by_performance(performance_data) do
    performance_data
    |> Enum.sort_by(fn {_id, perf} -> perf.performance_score end, :desc)
    |> Enum.with_index(1)
    |> Enum.map(fn {{agent_id, perf}, rank} ->
      %{
        rank: rank,
        agent_id: agent_id,
        performance_score: perf.performance_score,
        agent_type: perf.agent_type
      }
    end)
  end

  defp compare_metrics_across_agents(performance_data) do
    all_metrics = performance_data
    |> Enum.flat_map(fn {agent_id, perf} ->
      Enum.map(perf.aggregated_metrics, fn {metric_name, stats} ->
        {agent_id, metric_name, stats}
      end)
    end)
    |> Enum.group_by(fn {_agent_id, metric_name, _stats} -> metric_name end)

    Enum.map(all_metrics, fn {metric_name, agent_metrics} ->
      agent_values = Enum.map(agent_metrics, fn {agent_id, _metric_name, stats} ->
        {agent_id, stats.avg}
      end)

      values = Enum.map(agent_values, fn {_id, val} -> val end)

      {metric_name, %{
        agents: agent_values,
        overall_avg: if(length(values) > 0, do: Enum.sum(values) / length(values), else: 0.0),
        best_performer: Enum.max_by(agent_values, fn {_id, val} -> val end, fn -> nil end),
        worst_performer: Enum.min_by(agent_values, fn {_id, val} -> val end, fn -> nil end)
      }}
    end)
    |> Enum.into(%{})
  end

  defp generate_comparison_insights(performance_data) do
    insights = []

    # Performance spread insight
    scores = Enum.map(performance_data, fn {_id, perf} -> perf.performance_score end)
    score_range = Enum.max(scores) - Enum.min(scores)

    insights = if score_range > 0.3 do
      ["Significant performance variation detected across agents" | insights]
    else
      ["Agent performance is relatively consistent" | insights]
    end

    # Agent type insights
    type_performance = performance_data
    |> Enum.group_by(fn {_id, perf} -> perf.agent_type end)
    |> Enum.map(fn {type, agents} ->
      avg_score = agents
      |> Enum.map(fn {_id, perf} -> perf.performance_score end)
      |> (fn scores -> Enum.sum(scores) / length(scores) end).()

      {type, avg_score}
    end)

    if length(type_performance) > 1 do
      best_type = Enum.max_by(type_performance, fn {_type, score} -> score end)
      insights = ["#{elem(best_type, 0)} agents show the best average performance" | insights]
    end

    insights
  end
end
