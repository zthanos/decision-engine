defmodule DecisionEngine.ReflectionAgent do
  @moduledoc """
  The ReflectionAgent evaluates domain configuration quality and generates improvement feedback.

  This module implements the core reflection capabilities for the agentic reflection pattern,
  providing comprehensive quality assessment of domain configurations generated from PDF processing.
  """

  alias DecisionEngine.Types
  alias DecisionEngine.QualityScore
  alias DecisionEngine.ReflectionFeedback

  @doc """
  Evaluates a domain configuration for quality across multiple dimensions.

  Performs comprehensive quality assessment including signal field evaluation,
  decision pattern analysis, and domain description review.

  ## Parameters
  - domain_config: The domain configuration map to evaluate

  ## Returns
  - {:ok, evaluation_results} on successful evaluation
  - {:error, reason} if evaluation fails
  """
  @spec evaluate_configuration(map()) :: {:ok, map()} | {:error, String.t()}
  def evaluate_configuration(domain_config) when is_map(domain_config) do
    with :ok <- Types.validate_rule_config(domain_config) do
      evaluation = %{
        signal_fields: evaluate_signal_fields(domain_config),
        decision_patterns: evaluate_decision_patterns(domain_config),
        domain_description: evaluate_domain_description(domain_config),
        overall_structure: evaluate_overall_structure(domain_config)
      }

      {:ok, evaluation}
    else
      {:error, reason} -> {:error, "Configuration validation failed: #{reason}"}
    end
  end
  def evaluate_configuration(_), do: {:error, "Domain configuration must be a map"}

  @doc """
  Calculates comprehensive quality scores for a domain configuration.

  Uses evaluation results to compute weighted quality metrics according to
  the specified weights: completeness (30%), accuracy (25%), consistency (25%), usability (20%).

  ## Parameters
  - domain_config: The domain configuration map to score

  ## Returns
  - {:ok, quality_score} on successful scoring
  - {:error, reason} if scoring fails
  """
  @spec calculate_quality_scores(map()) :: {:ok, QualityScore.t()} | {:error, String.t()}
  def calculate_quality_scores(domain_config) when is_map(domain_config) do
    case evaluate_configuration(domain_config) do
      {:ok, evaluation_results} ->
        quality_score = QualityScore.calculate_quality_score(evaluation_results)
        {:ok, quality_score}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates comprehensive improvement feedback based on evaluation results.

  Creates specific, actionable recommendations with priority ordering for
  enhancing domain configuration quality across all dimensions.

  ## Parameters
  - domain_config: The domain configuration map to analyze

  ## Returns
  - {:ok, reflection_feedback} on successful feedback generation
  - {:error, reason} if feedback generation fails
  """
  @spec generate_feedback(map()) :: {:ok, ReflectionFeedback.t()} | {:error, String.t()}
  def generate_feedback(domain_config) when is_map(domain_config) do
    with {:ok, evaluation_results} <- evaluate_configuration(domain_config),
         {:ok, quality_score} <- calculate_quality_scores(domain_config) do
      feedback = ReflectionFeedback.generate_feedback(evaluation_results, quality_score)
      {:ok, feedback}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions for signal field evaluation
  defp evaluate_signal_fields(config) do
    signals_fields = config["signals_fields"] || []
    patterns = config["patterns"] || []

    %{
      relevance_score: calculate_field_relevance(signals_fields, patterns),
      naming_consistency: evaluate_naming_consistency(signals_fields),
      coverage_completeness: evaluate_coverage_completeness(signals_fields, patterns),
      field_count: length(signals_fields),
      unused_fields: find_unused_fields(signals_fields, patterns)
    }
  end

  defp calculate_field_relevance(signals_fields, patterns) do
    if length(signals_fields) == 0, do: 0.0

    used_fields =
      patterns
      |> Enum.flat_map(fn pattern ->
        conditions = (pattern["use_when"] || []) ++ (pattern["avoid_when"] || [])
        Enum.map(conditions, & &1["field"])
      end)
      |> Enum.uniq()

    used_count = length(used_fields)
    total_count = length(signals_fields)

    if total_count > 0, do: used_count / total_count, else: 0.0
  end

  defp evaluate_naming_consistency(signals_fields) do
    if length(signals_fields) == 0, do: 1.0

    # Check for consistent naming patterns (snake_case, descriptive names)
    consistent_names =
      signals_fields
      |> Enum.count(fn field ->
        String.match?(field, ~r/^[a-z][a-z0-9_]*$/) and String.length(field) > 2
      end)

    # Prevent division by zero
    if length(signals_fields) > 0 do
      consistent_names / length(signals_fields)
    else
      1.0
    end
  end

  defp evaluate_coverage_completeness(signals_fields, patterns) do
    if length(patterns) == 0, do: 0.0

    # Evaluate how well signal fields cover the decision space
    pattern_complexity =
      patterns
      |> Enum.map(fn pattern ->
        conditions = (pattern["use_when"] || []) ++ (pattern["avoid_when"] || [])
        length(conditions)
      end)
      |> Enum.sum()

    field_count = length(signals_fields)

    # Simple heuristic: more fields generally enable more complex patterns
    cond do
      field_count == 0 -> 0.0
      pattern_complexity == 0 -> 0.5
      true -> min(1.0, (field_count * 2) / pattern_complexity)
    end
  end

  defp find_unused_fields(signals_fields, patterns) do
    used_fields =
      patterns
      |> Enum.flat_map(fn pattern ->
        conditions = (pattern["use_when"] || []) ++ (pattern["avoid_when"] || [])
        Enum.map(conditions, & &1["field"])
      end)
      |> MapSet.new()

    signals_fields
    |> Enum.reject(&MapSet.member?(used_fields, &1))
  end

  # Private functions for decision pattern evaluation
  defp evaluate_decision_patterns(config) do
    patterns = config["patterns"] || []

    %{
      logical_consistency: evaluate_logical_consistency(patterns),
      mutual_exclusivity: evaluate_mutual_exclusivity(patterns),
      practical_applicability: evaluate_practical_applicability(patterns),
      pattern_count: length(patterns),
      complexity_distribution: analyze_complexity_distribution(patterns)
    }
  end

  defp evaluate_logical_consistency(patterns) do
    if length(patterns) == 0, do: 0.0

    # Check for patterns with contradictory conditions
    consistent_patterns =
      patterns
      |> Enum.count(fn pattern ->
        use_when = pattern["use_when"] || []
        avoid_when = pattern["avoid_when"] || []

        # Simple check: ensure use_when and avoid_when don't have direct contradictions
        not has_direct_contradictions?(use_when, avoid_when)
      end)

    # Prevent division by zero
    if length(patterns) > 0 do
      consistent_patterns / length(patterns)
    else
      0.0
    end
  end

  defp has_direct_contradictions?(use_when, avoid_when) do
    use_conditions = Enum.map(use_when, &{&1["field"], &1["value"]})
    avoid_conditions = Enum.map(avoid_when, &{&1["field"], &1["value"]})

    # Check for same field with same value in both use_when and avoid_when
    Enum.any?(use_conditions, fn condition ->
      condition in avoid_conditions
    end)
  end

  defp evaluate_mutual_exclusivity(patterns) do
    if length(patterns) <= 1, do: 1.0

    # Evaluate how well patterns are differentiated from each other
    pattern_pairs = for p1 <- patterns, p2 <- patterns, p1 != p2, do: {p1, p2}

    if length(pattern_pairs) == 0 do
      1.0
    else
      exclusive_pairs =
        pattern_pairs
        |> Enum.count(fn {p1, p2} ->
          patterns_are_exclusive?(p1, p2)
        end)

      # Prevent division by zero
      if length(pattern_pairs) > 0 do
        exclusive_pairs / length(pattern_pairs)
      else
        1.0
      end
    end
  end

  defp patterns_are_exclusive?(pattern1, pattern2) do
    # Simple heuristic: patterns are exclusive if they have different outcomes
    # or if one's use_when overlaps with the other's avoid_when
    pattern1["outcome"] != pattern2["outcome"]
  end

  defp evaluate_practical_applicability(patterns) do
    if length(patterns) == 0, do: 0.0

    # Evaluate based on pattern completeness and realistic conditions
    applicable_patterns =
      patterns
      |> Enum.count(fn pattern ->
        has_complete_structure?(pattern) and has_realistic_conditions?(pattern)
      end)

    # Prevent division by zero
    if length(patterns) > 0 do
      applicable_patterns / length(patterns)
    else
      0.0
    end
  end

  defp has_complete_structure?(pattern) do
    required_fields = ["id", "outcome", "score", "summary", "use_when", "avoid_when"]
    Enum.all?(required_fields, &Map.has_key?(pattern, &1))
  end

  defp has_realistic_conditions?(pattern) do
    use_when = pattern["use_when"] || []
    avoid_when = pattern["avoid_when"] || []

    # Check that conditions are not empty and have valid structure
    length(use_when) > 0 and length(avoid_when) >= 0 and
    Enum.all?(use_when ++ avoid_when, &valid_condition?/1)
  end

  defp valid_condition?(condition) do
    Map.has_key?(condition, "field") and
    Map.has_key?(condition, "op") and
    Map.has_key?(condition, "value")
  end

  defp analyze_complexity_distribution(patterns) do
    if length(patterns) == 0, do: %{simple: 0, moderate: 0, complex: 0}

    complexity_counts =
      patterns
      |> Enum.map(fn pattern ->
        condition_count = length(pattern["use_when"] || []) + length(pattern["avoid_when"] || [])
        cond do
          condition_count <= 2 -> :simple
          condition_count <= 5 -> :moderate
          true -> :complex
        end
      end)
      |> Enum.frequencies()

    total = length(patterns)

    # Prevent division by zero
    if total > 0 do
      %{
        simple: Map.get(complexity_counts, :simple, 0) / total,
        moderate: Map.get(complexity_counts, :moderate, 0) / total,
        complex: Map.get(complexity_counts, :complex, 0) / total
      }
    else
      %{simple: 0, moderate: 0, complex: 0}
    end
  end

  # Private functions for domain description evaluation
  defp evaluate_domain_description(config) do
    domain_name = config["domain"] || ""

    %{
      clarity_score: evaluate_description_clarity(domain_name),
      accuracy_score: evaluate_description_accuracy(config),
      alignment_score: evaluate_alignment_with_patterns(config)
    }
  end

  defp evaluate_description_clarity(domain_name) do
    cond do
      String.length(domain_name) == 0 -> 0.0
      String.length(domain_name) < 3 -> 0.3
      String.match?(domain_name, ~r/^[a-z][a-z0-9_]*$/) -> 0.8
      true -> 0.6
    end
  end

  defp evaluate_description_accuracy(config) do
    # Evaluate based on consistency between domain name and patterns
    domain_name = config["domain"] || ""
    patterns = config["patterns"] || []

    if length(patterns) == 0, do: 0.5

    # Check if pattern outcomes align with domain name
    aligned_patterns =
      patterns
      |> Enum.count(fn pattern ->
        outcome = pattern["outcome"] || ""
        String.contains?(outcome, domain_name) or String.contains?(domain_name, "platform")
      end)

    # Prevent division by zero
    if length(patterns) > 0 do
      aligned_patterns / length(patterns)
    else
      0.5
    end
  end

  defp evaluate_alignment_with_patterns(config) do
    domain_name = config["domain"] || ""
    signals_fields = config["signals_fields"] || []

    # Simple heuristic: domain name should relate to signal fields
    if length(signals_fields) == 0, do: 0.5

    related_fields =
      signals_fields
      |> Enum.count(fn field ->
        domain_words = String.split(domain_name, "_")
        Enum.any?(domain_words, &String.contains?(field, &1))
      end)

    if length(signals_fields) > 0, do: related_fields / length(signals_fields), else: 0.5
  end

  # Private functions for overall structure evaluation
  defp evaluate_overall_structure(config) do
    %{
      completeness_score: evaluate_structural_completeness(config),
      coherence_score: evaluate_structural_coherence(config),
      usability_score: evaluate_structural_usability(config)
    }
  end

  defp evaluate_structural_completeness(config) do
    required_sections = ["domain", "signals_fields", "patterns"]
    optional_sections = ["description", "metadata", "version"]

    required_present = Enum.count(required_sections, &Map.has_key?(config, &1))
    optional_present = Enum.count(optional_sections, &Map.has_key?(config, &1))

    # Weight required sections more heavily
    (required_present * 0.8 + optional_present * 0.2) / (length(required_sections) * 0.8 + length(optional_sections) * 0.2)
  end

  defp evaluate_structural_coherence(config) do
    # Evaluate internal consistency across all sections
    signals_fields = config["signals_fields"] || []
    patterns = config["patterns"] || []

    if length(signals_fields) == 0 or length(patterns) == 0, do: 0.5

    # Check field usage consistency
    field_usage_score = calculate_field_relevance(signals_fields, patterns)

    # Check pattern outcome consistency
    outcomes = patterns |> Enum.map(& &1["outcome"]) |> Enum.uniq()
    outcome_consistency = if length(outcomes) <= 3, do: 1.0, else: 0.7

    (field_usage_score + outcome_consistency) / 2
  end

  defp evaluate_structural_usability(config) do
    patterns = config["patterns"] || []
    signals_fields = config["signals_fields"] || []

    # Evaluate based on practical usability factors
    pattern_usability = if length(patterns) > 0, do: evaluate_practical_applicability(patterns), else: 0.0
    field_usability = if length(signals_fields) > 0, do: evaluate_naming_consistency(signals_fields), else: 0.0

    (pattern_usability + field_usability) / 2
  end


end
