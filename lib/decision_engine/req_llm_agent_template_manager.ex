defmodule DecisionEngine.ReqLLMAgentTemplateManager do
  @moduledoc """
  Advanced template management for agentic workflows.

  This module provides dynamic prompt template generation, template versioning,
  template optimization, and A/B testing capabilities for agent prompts.
  Supports complex template management scenarios for the agentic reflection pattern.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger
  alias DecisionEngine.ReqLLMCorrelation
  alias DecisionEngine.ReqLLMAgentPromptManager

  @type template_version :: %{
    version: String.t(),
    template_id: String.t(),
    changes: [String.t()],
    performance_metrics: map(),
    created_at: DateTime.t(),
    created_by: String.t()
  }

  @type ab_test :: %{
    id: String.t(),
    name: String.t(),
    template_a_id: String.t(),
    template_b_id: String.t(),
    traffic_split: float(),
    status: :active | :paused | :completed,
    metrics: map(),
    start_date: DateTime.t(),
    end_date: DateTime.t() | nil
  }

  @type template_generation_config :: %{
    agent_type: atom(),
    use_case: String.t(),
    target_metrics: map(),
    constraints: map(),
    optimization_goals: [atom()]
  }

  @doc """
  Generates a new template dynamically based on configuration.

  ## Parameters
  - generation_config: Configuration for template generation
  - base_template_id: Optional base template to start from
  - options: Additional generation options

  ## Returns
  - {:ok, template} on successful generation
  - {:error, reason} if generation fails
  """
  @spec generate_template(template_generation_config(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def generate_template(generation_config, base_template_id \\ nil, options \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, base_template} <- get_base_template(base_template_id),
         {:ok, generated_content} <- perform_template_generation(generation_config, base_template, options),
         {:ok, template} <- ReqLLMAgentPromptManager.create_template(generated_content, generation_config.agent_type),
         :ok <- store_generation_metadata(template.id, generation_config, options) do

      ReqLLMLogger.log_agent_event(:template_generated, %{
        template_id: template.id,
        agent_type: generation_config.agent_type,
        use_case: generation_config.use_case,
        base_template_id: base_template_id
      }, %{correlation_id: correlation_id})

      {:ok, template}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:template_generation_failed, %{
          agent_type: generation_config.agent_type,
          use_case: generation_config.use_case,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Creates a new version of an existing template.

  ## Parameters
  - template_id: ID of the template to version
  - changes: List of changes being made
  - updated_content: New template content
  - version_metadata: Additional version metadata

  ## Returns
  - {:ok, {new_template, version_info}} on success
  - {:error, reason} if versioning fails
  """
  @spec create_template_version(String.t(), [String.t()], map(), map()) :: {:ok, {map(), template_version()}} | {:error, term()}
  def create_template_version(template_id, changes, updated_content, version_metadata \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, original_template} <- ReqLLMAgentPromptManager.get_template(template_id),
         {:ok, new_version} <- calculate_next_version(template_id),
         {:ok, new_template} <- create_versioned_template(original_template, updated_content, new_version),
         {:ok, version_info} <- create_version_record(template_id, new_template.id, new_version, changes, version_metadata),
         :ok <- store_version_info(version_info) do

      ReqLLMLogger.log_agent_event(:template_versioned, %{
        original_template_id: template_id,
        new_template_id: new_template.id,
        version: new_version,
        changes_count: length(changes)
      }, %{correlation_id: correlation_id})

      {:ok, {new_template, version_info}}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:template_versioning_failed, %{
          template_id: template_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Sets up an A/B test between two templates.

  ## Parameters
  - test_name: Name of the A/B test
  - template_a_id: ID of template A
  - template_b_id: ID of template B
  - traffic_split: Percentage of traffic for template A (0.0 to 1.0)
  - test_config: Additional test configuration

  ## Returns
  - {:ok, ab_test} on successful setup
  - {:error, reason} if setup fails
  """
  @spec setup_ab_test(String.t(), String.t(), String.t(), float(), map()) :: {:ok, ab_test()} | {:error, term()}
  def setup_ab_test(test_name, template_a_id, template_b_id, traffic_split, test_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with :ok <- validate_ab_test_params(template_a_id, template_b_id, traffic_split),
         {:ok, test_id} <- generate_ab_test_id(),
         {:ok, ab_test} <- create_ab_test_record(test_id, test_name, template_a_id, template_b_id, traffic_split, test_config),
         :ok <- store_ab_test(ab_test) do

      ReqLLMLogger.log_agent_event(:ab_test_created, %{
        test_id: test_id,
        test_name: test_name,
        template_a_id: template_a_id,
        template_b_id: template_b_id,
        traffic_split: traffic_split
      }, %{correlation_id: correlation_id})

      {:ok, ab_test}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:ab_test_creation_failed, %{
          test_name: test_name,
          template_a_id: template_a_id,
          template_b_id: template_b_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Selects a template for A/B testing based on traffic split.

  ## Parameters
  - test_id: ID of the A/B test
  - user_id: Optional user ID for consistent assignment

  ## Returns
  - {:ok, template_id} selected template
  - {:error, reason} if selection fails
  """
  @spec select_template_for_test(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def select_template_for_test(test_id, user_id \\ nil) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, ab_test} <- get_ab_test(test_id),
         :ok <- validate_test_active(ab_test),
         {:ok, selected_template_id} <- perform_template_selection(ab_test, user_id),
         :ok <- record_test_assignment(test_id, selected_template_id, user_id) do

      ReqLLMLogger.log_agent_event(:template_selected_for_test, %{
        test_id: test_id,
        selected_template_id: selected_template_id,
        user_id: user_id
      }, %{correlation_id: correlation_id})

      {:ok, selected_template_id}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:template_selection_failed, %{
          test_id: test_id,
          user_id: user_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Records performance metrics for a template in an A/B test.

  ## Parameters
  - test_id: ID of the A/B test
  - template_id: ID of the template used
  - metrics: Performance metrics to record
  - context: Additional context information

  ## Returns
  - :ok on successful recording
  - {:error, reason} if recording fails
  """
  @spec record_test_metrics(String.t(), String.t(), map(), map()) :: :ok | {:error, term()}
  def record_test_metrics(test_id, template_id, metrics, context \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, ab_test} <- get_ab_test(test_id),
         :ok <- validate_template_in_test(ab_test, template_id),
         :ok <- store_test_metrics(test_id, template_id, metrics, context),
         {:ok, updated_test} <- update_test_aggregated_metrics(ab_test, template_id, metrics) do

      ReqLLMLogger.log_agent_event(:test_metrics_recorded, %{
        test_id: test_id,
        template_id: template_id,
        metrics_count: map_size(metrics)
      }, %{correlation_id: correlation_id})

      :ok
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:test_metrics_recording_failed, %{
          test_id: test_id,
          template_id: template_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Analyzes A/B test results and determines the winner.

  ## Parameters
  - test_id: ID of the A/B test to analyze
  - analysis_config: Configuration for analysis

  ## Returns
  - {:ok, analysis_results} on successful analysis
  - {:error, reason} if analysis fails
  """
  @spec analyze_ab_test_results(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def analyze_ab_test_results(test_id, analysis_config \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, ab_test} <- get_ab_test(test_id),
         {:ok, test_metrics} <- get_all_test_metrics(test_id),
         {:ok, analysis_results} <- perform_statistical_analysis(ab_test, test_metrics, analysis_config),
         :ok <- store_analysis_results(test_id, analysis_results) do

      ReqLLMLogger.log_agent_event(:ab_test_analyzed, %{
        test_id: test_id,
        winner: Map.get(analysis_results, :winner),
        confidence: Map.get(analysis_results, :confidence),
        sample_size: Map.get(analysis_results, :total_samples)
      }, %{correlation_id: correlation_id})

      {:ok, analysis_results}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:ab_test_analysis_failed, %{
          test_id: test_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Optimizes a template based on performance data.

  ## Parameters
  - template_id: ID of the template to optimize
  - performance_data: Historical performance data
  - optimization_goals: Goals for optimization

  ## Returns
  - {:ok, optimized_template} on successful optimization
  - {:error, reason} if optimization fails
  """
  @spec optimize_template_performance(String.t(), map(), [atom()]) :: {:ok, map()} | {:error, term()}
  def optimize_template_performance(template_id, performance_data, optimization_goals) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, template} <- ReqLLMAgentPromptManager.get_template(template_id),
         {:ok, optimization_suggestions} <- analyze_performance_data(performance_data, optimization_goals),
         {:ok, optimized_template} <- apply_optimization_suggestions(template, optimization_suggestions),
         {:ok, new_template} <- ReqLLMAgentPromptManager.create_template(optimized_template, template.metadata.agent_type) do

      ReqLLMLogger.log_agent_event(:template_optimized, %{
        original_template_id: template_id,
        optimized_template_id: new_template.id,
        optimization_goals: optimization_goals,
        suggestions_applied: length(optimization_suggestions)
      }, %{correlation_id: correlation_id})

      {:ok, new_template}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:template_optimization_failed, %{
          template_id: template_id,
          optimization_goals: optimization_goals,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  # Private Functions

  defp get_base_template(nil), do: {:ok, nil}
  defp get_base_template(template_id) do
    ReqLLMAgentPromptManager.get_template(template_id)
  end

  defp perform_template_generation(generation_config, base_template, options) do
    # Generate template content based on configuration
    template_content = case base_template do
      nil -> generate_from_scratch(generation_config, options)
      template -> enhance_existing_template(template, generation_config, options)
    end

    {:ok, template_content}
  end

  defp generate_from_scratch(generation_config, options) do
    # Basic template generation based on agent type and use case
    base_prompt = case generation_config.agent_type do
      :reflection ->
        "You are a reflection agent tasked with {{task}}. Please analyze the following: {{input}}"
      :refinement ->
        "You are a refinement agent. Your goal is to improve {{target}}. Current state: {{current_state}}"
      :evaluation ->
        "You are an evaluation agent. Please evaluate {{subject}} based on {{criteria}}."
      _ ->
        "You are an AI agent. Please help with {{task}}."
    end

    %{
      name: "Generated #{generation_config.agent_type} Template",
      description: "Auto-generated template for #{generation_config.use_case}",
      template: base_prompt,
      variables: extract_variables_from_template(base_prompt),
      response_format: %{type: :json, required_fields: ["analysis", "recommendations"]},
      validation_rules: generate_validation_rules(generation_config)
    }
  end

  defp enhance_existing_template(base_template, generation_config, _options) do
    # Enhance existing template based on generation config
    enhanced_template = base_template.template

    # Add optimization hints based on target metrics
    enhanced_template = case Map.get(generation_config.target_metrics, :response_time_ms) do
      time when is_number(time) and time < 3000 ->
        enhanced_template <> "\n\nPlease provide a concise response."
      _ ->
        enhanced_template
    end

    %{
      name: "Enhanced " <> base_template.name,
      description: base_template.description <> " (Enhanced for #{generation_config.use_case})",
      template: enhanced_template,
      variables: base_template.variables,
      response_format: base_template.response_format,
      validation_rules: base_template.validation_rules ++ generate_validation_rules(generation_config)
    }
  end

  defp extract_variables_from_template(template) do
    Regex.scan(~r/\{\{([^}]+)\}\}/, template)
    |> Enum.map(fn [_, var] -> var end)
    |> Enum.uniq()
  end

  defp generate_validation_rules(generation_config) do
    rules = []

    # Add length constraints based on optimization goals
    rules = if :speed in generation_config.optimization_goals do
      [%{type: :max_length, value: 2000} | rules]
    else
      rules
    end

    # Add content requirements based on use case
    rules = case generation_config.use_case do
      use_case when use_case in ["analysis", "evaluation"] ->
        [%{type: :required_content, value: "analysis"} | rules]
      _ ->
        rules
    end

    rules
  end

  defp store_generation_metadata(template_id, generation_config, options) do
    metadata = %{
      template_id: template_id,
      generation_config: generation_config,
      generation_options: options,
      generated_at: DateTime.utc_now()
    }

    table_name = :req_llm_template_generation_metadata

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {template_id, metadata})
    :ok
  end

  defp calculate_next_version(template_id) do
    # Get existing versions for this template
    versions = get_template_versions(template_id)

    case versions do
      [] ->
        {:ok, "1.0.0"}
      existing_versions ->
        latest_version = Enum.max_by(existing_versions, fn v -> parse_version(v.version) end)
        {:ok, increment_patch_version(latest_version.version)}
    end
  end

  defp parse_version(version_string) do
    case String.split(version_string, ".") do
      [major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}
      _ ->
        {1, 0, 0}
    end
  end

  defp increment_patch_version(version_string) do
    {major, minor, patch} = parse_version(version_string)
    "#{major}.#{minor}.#{patch + 1}"
  end

  defp create_versioned_template(original_template, updated_content, new_version) do
    versioned_content = Map.merge(updated_content, %{
      name: original_template.name <> " v#{new_version}",
      metadata: Map.merge(original_template.metadata, %{
        version: new_version,
        parent_template_id: original_template.id
      })
    })

    ReqLLMAgentPromptManager.create_template(versioned_content, original_template.metadata.agent_type)
  end

  defp create_version_record(original_template_id, new_template_id, version, changes, metadata) do
    version_info = %{
      version: version,
      template_id: new_template_id,
      parent_template_id: original_template_id,
      changes: changes,
      performance_metrics: %{},
      created_at: DateTime.utc_now(),
      created_by: Map.get(metadata, :created_by, "system"),
      metadata: metadata
    }

    {:ok, version_info}
  end

  defp store_version_info(version_info) do
    table_name = :req_llm_template_versions

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :bag, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {version_info.parent_template_id, version_info})
    :ok
  end

  defp get_template_versions(template_id) do
    table_name = :req_llm_template_versions

    case :ets.whereis(table_name) do
      :undefined ->
        []
      _ ->
        :ets.lookup(table_name, template_id)
        |> Enum.map(fn {_id, version_info} -> version_info end)
    end
  end

  defp validate_ab_test_params(template_a_id, template_b_id, traffic_split) do
    with {:ok, _} <- ReqLLMAgentPromptManager.get_template(template_a_id),
         {:ok, _} <- ReqLLMAgentPromptManager.get_template(template_b_id) do
      if traffic_split >= 0.0 and traffic_split <= 1.0 do
        :ok
      else
        {:error, "Traffic split must be between 0.0 and 1.0"}
      end
    end
  end

  defp generate_ab_test_id do
    id = :crypto.strong_rand_bytes(12) |> Base.encode64(padding: false)
    {:ok, "abtest_" <> id}
  end

  defp create_ab_test_record(test_id, test_name, template_a_id, template_b_id, traffic_split, test_config) do
    ab_test = %{
      id: test_id,
      name: test_name,
      template_a_id: template_a_id,
      template_b_id: template_b_id,
      traffic_split: traffic_split,
      status: :active,
      metrics: %{
        template_a: %{requests: 0, success_rate: 0.0, avg_response_time: 0.0},
        template_b: %{requests: 0, success_rate: 0.0, avg_response_time: 0.0}
      },
      start_date: DateTime.utc_now(),
      end_date: Map.get(test_config, :end_date),
      config: test_config
    }

    {:ok, ab_test}
  end

  defp store_ab_test(ab_test) do
    table_name = :req_llm_ab_tests

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {ab_test.id, ab_test})
    :ok
  end

  defp get_ab_test(test_id) do
    table_name = :req_llm_ab_tests

    case :ets.lookup(table_name, test_id) do
      [{^test_id, ab_test}] ->
        {:ok, ab_test}
      [] ->
        {:error, "A/B test not found: #{test_id}"}
    end
  end

  defp validate_test_active(ab_test) do
    case ab_test.status do
      :active -> :ok
      status -> {:error, "A/B test is not active, current status: #{status}"}
    end
  end

  defp perform_template_selection(ab_test, user_id) do
    # Deterministic selection based on user_id if provided, otherwise random
    selection_value = case user_id do
      nil -> :rand.uniform()
      user_id ->
        # Hash user_id to get consistent selection
        hash = :crypto.hash(:md5, user_id) |> :binary.decode_unsigned()
        (hash / :math.pow(2, 128))
    end

    selected_template_id = if selection_value <= ab_test.traffic_split do
      ab_test.template_a_id
    else
      ab_test.template_b_id
    end

    {:ok, selected_template_id}
  end

  defp record_test_assignment(test_id, selected_template_id, user_id) do
    assignment = %{
      test_id: test_id,
      template_id: selected_template_id,
      user_id: user_id,
      assigned_at: DateTime.utc_now()
    }

    table_name = :req_llm_test_assignments

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :bag, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {test_id, assignment})
    :ok
  end

  defp validate_template_in_test(ab_test, template_id) do
    if template_id in [ab_test.template_a_id, ab_test.template_b_id] do
      :ok
    else
      {:error, "Template #{template_id} is not part of test #{ab_test.id}"}
    end
  end

  defp store_test_metrics(test_id, template_id, metrics, context) do
    metric_record = %{
      test_id: test_id,
      template_id: template_id,
      metrics: metrics,
      context: context,
      recorded_at: DateTime.utc_now()
    }

    table_name = :req_llm_test_metrics

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :bag, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {test_id, metric_record})
    :ok
  end

  defp update_test_aggregated_metrics(ab_test, template_id, new_metrics) do
    # Update aggregated metrics for the test
    template_key = if template_id == ab_test.template_a_id, do: :template_a, else: :template_b

    current_metrics = ab_test.metrics[template_key]
    updated_metrics = %{
      requests: current_metrics.requests + 1,
      success_rate: calculate_updated_success_rate(current_metrics, new_metrics),
      avg_response_time: calculate_updated_avg_response_time(current_metrics, new_metrics)
    }

    updated_ab_test = %{ab_test |
      metrics: Map.put(ab_test.metrics, template_key, updated_metrics)
    }

    store_ab_test(updated_ab_test)
    {:ok, updated_ab_test}
  end

  defp calculate_updated_success_rate(current_metrics, new_metrics) do
    current_total = current_metrics.requests * current_metrics.success_rate
    new_success = if Map.get(new_metrics, :success, true), do: 1, else: 0

    (current_total + new_success) / (current_metrics.requests + 1)
  end

  defp calculate_updated_avg_response_time(current_metrics, new_metrics) do
    current_total = current_metrics.requests * current_metrics.avg_response_time
    new_response_time = Map.get(new_metrics, :response_time_ms, 0)

    (current_total + new_response_time) / (current_metrics.requests + 1)
  end

  defp get_all_test_metrics(test_id) do
    table_name = :req_llm_test_metrics

    case :ets.whereis(table_name) do
      :undefined ->
        {:ok, []}
      _ ->
        metrics = :ets.lookup(table_name, test_id)
        |> Enum.map(fn {_id, metric_record} -> metric_record end)
        {:ok, metrics}
    end
  end

  defp perform_statistical_analysis(ab_test, test_metrics, _analysis_config) do
    # Simple statistical analysis
    template_a_metrics = Enum.filter(test_metrics, fn m -> m.template_id == ab_test.template_a_id end)
    template_b_metrics = Enum.filter(test_metrics, fn m -> m.template_id == ab_test.template_b_id end)

    a_success_rate = calculate_success_rate(template_a_metrics)
    b_success_rate = calculate_success_rate(template_b_metrics)

    a_avg_response_time = calculate_avg_response_time(template_a_metrics)
    b_avg_response_time = calculate_avg_response_time(template_b_metrics)

    # Determine winner based on success rate and response time
    winner = cond do
      a_success_rate > b_success_rate -> ab_test.template_a_id
      b_success_rate > a_success_rate -> ab_test.template_b_id
      a_avg_response_time < b_avg_response_time -> ab_test.template_a_id
      true -> ab_test.template_b_id
    end

    analysis_results = %{
      winner: winner,
      confidence: calculate_confidence(template_a_metrics, template_b_metrics),
      template_a_metrics: %{
        success_rate: a_success_rate,
        avg_response_time: a_avg_response_time,
        sample_size: length(template_a_metrics)
      },
      template_b_metrics: %{
        success_rate: b_success_rate,
        avg_response_time: b_avg_response_time,
        sample_size: length(template_b_metrics)
      },
      total_samples: length(test_metrics),
      analyzed_at: DateTime.utc_now()
    }

    {:ok, analysis_results}
  end

  defp calculate_success_rate(metrics) do
    if length(metrics) == 0 do
      0.0
    else
      successful = Enum.count(metrics, fn m -> Map.get(m.metrics, :success, true) end)
      successful / length(metrics)
    end
  end

  defp calculate_avg_response_time(metrics) do
    if length(metrics) == 0 do
      0.0
    else
      total_time = Enum.sum(Enum.map(metrics, fn m -> Map.get(m.metrics, :response_time_ms, 0) end))
      total_time / length(metrics)
    end
  end

  defp calculate_confidence(template_a_metrics, template_b_metrics) do
    # Simple confidence calculation based on sample size
    total_samples = length(template_a_metrics) + length(template_b_metrics)

    cond do
      total_samples >= 1000 -> 0.95
      total_samples >= 500 -> 0.90
      total_samples >= 100 -> 0.80
      total_samples >= 50 -> 0.70
      true -> 0.50
    end
  end

  defp store_analysis_results(test_id, analysis_results) do
    table_name = :req_llm_test_analysis

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {test_id, analysis_results})
    :ok
  end

  defp analyze_performance_data(performance_data, optimization_goals) do
    suggestions = []

    # Analyze response time
    suggestions = if :speed in optimization_goals do
      avg_response_time = Map.get(performance_data, :avg_response_time_ms, 0)
      if avg_response_time > 3000 do
        [%{type: :reduce_prompt_length, priority: :high} | suggestions]
      else
        suggestions
      end
    else
      suggestions
    end

    # Analyze success rate
    suggestions = if :accuracy in optimization_goals do
      success_rate = Map.get(performance_data, :success_rate, 1.0)
      if success_rate < 0.8 do
        [%{type: :improve_validation, priority: :high} | suggestions]
      else
        suggestions
      end
    else
      suggestions
    end

    # Analyze user satisfaction
    suggestions = if :user_satisfaction in optimization_goals do
      satisfaction_score = Map.get(performance_data, :satisfaction_score, 0.8)
      if satisfaction_score < 0.7 do
        [%{type: :enhance_clarity, priority: :medium} | suggestions]
      else
        suggestions
      end
    else
      suggestions
    end

    {:ok, suggestions}
  end

  defp apply_optimization_suggestions(template, suggestions) do
    optimized_template = Enum.reduce(suggestions, template, fn suggestion, acc ->
      apply_single_suggestion(acc, suggestion)
    end)

    {:ok, optimized_template}
  end

  defp apply_single_suggestion(template, suggestion) do
    case suggestion.type do
      :reduce_prompt_length ->
        # Simplify the template to reduce length
        simplified_template = String.replace(template.template, ~r/\s+/, " ")
        |> String.trim()
        %{template | template: simplified_template}

      :improve_validation ->
        # Add more validation rules
        new_rules = [
          %{type: :required_field, field: "confidence_score"},
          %{type: :field_type, field: "confidence_score", expected_type: :number}
        ]
        %{template | validation_rules: template.validation_rules ++ new_rules}

      :enhance_clarity ->
        # Add clarity instructions
        enhanced_template = template.template <> "\n\nPlease provide clear, step-by-step reasoning."
        %{template | template: enhanced_template}

      _ ->
        template
    end
  end
end
