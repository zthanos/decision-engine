defmodule DecisionEngine.QualityValidator do
  @moduledoc """
  Validates improvements and prevents quality degradation in domain configurations.

  This module provides validation logic for beneficial improvements, tracks improvement
  metrics, and ensures that refinement processes actually enhance configuration quality
  rather than degrading it.
  """

  alias DecisionEngine.QualityScore
  alias DecisionEngine.ReflectionAgent
  alias DecisionEngine.Types

  @type improvement_result :: %{
    is_improvement: boolean(),
    quality_change: float(),
    improved_dimensions: [String.t()],
    degraded_dimensions: [String.t()],
    validation_errors: [String.t()],
    recommendation: :accept | :reject | :conditional
  }

  @doc """
  Validates that refinements represent beneficial improvements over the original configuration.

  Compares original and refined configurations across all quality dimensions and determines
  whether the refinement should be accepted, rejected, or conditionally accepted.

  ## Parameters
  - original_config: The original domain configuration map
  - refined_config: The refined domain configuration map
  - min_improvement_threshold: Minimum improvement required (default 0.05)

  ## Returns
  - {:ok, improvement_result} with detailed validation analysis
  - {:error, reason} if validation fails
  """
  @spec validate_improvements(map(), map(), float()) :: {:ok, improvement_result()} | {:error, String.t()}
  def validate_improvements(original_config, refined_config, min_improvement_threshold \\ 0.05)
      when is_map(original_config) and is_map(refined_config) do

    with :ok <- Types.validate_rule_config(original_config),
         :ok <- Types.validate_rule_config(refined_config),
         {:ok, original_quality} <- ReflectionAgent.calculate_quality_scores(original_config),
         {:ok, refined_quality} <- ReflectionAgent.calculate_quality_scores(refined_config) do

      improvement_analysis = analyze_quality_improvements(original_quality, refined_quality)
      validation_errors = validate_configuration_integrity(original_config, refined_config)

      result = %{
        is_improvement: improvement_analysis.overall_improvement >= min_improvement_threshold,
        quality_change: improvement_analysis.overall_improvement,
        improved_dimensions: improvement_analysis.improved_dimensions,
        degraded_dimensions: improvement_analysis.degraded_dimensions,
        validation_errors: validation_errors,
        recommendation: determine_recommendation(improvement_analysis, validation_errors, min_improvement_threshold)
      }

      {:ok, result}
    else
      {:error, reason} -> {:error, "Quality validation failed: #{reason}"}
    end
  end

  @doc """
  Tracks improvement metrics across multiple refinement sessions.

  Maintains historical data about quality improvements to analyze refinement effectiveness
  over time and identify patterns in successful improvements.

  ## Parameters
  - improvement_history: List of previous improvement results
  - new_improvement: Latest improvement result to add to history

  ## Returns
  - Updated improvement history with aggregated metrics
  """
  @spec track_improvement_metrics([improvement_result()], improvement_result()) :: map()
  def track_improvement_metrics(improvement_history, new_improvement)
      when is_list(improvement_history) and is_map(new_improvement) do

    updated_history = [new_improvement | improvement_history]

    %{
      total_sessions: length(updated_history),
      successful_improvements: count_successful_improvements(updated_history),
      average_quality_gain: calculate_average_quality_gain(updated_history),
      most_improved_dimensions: identify_most_improved_dimensions(updated_history),
      common_degradation_areas: identify_common_degradation_areas(updated_history),
      improvement_trend: calculate_improvement_trend(updated_history),
      success_rate: calculate_success_rate(updated_history),
      history: Enum.take(updated_history, 50)  # Keep last 50 sessions
    }
  end

  @doc """
  Prevents quality degradation by validating that key quality metrics don't decrease significantly.

  ## Parameters
  - original_quality: Original QualityScore
  - refined_quality: Refined QualityScore
  - max_degradation_threshold: Maximum allowed degradation per dimension (default 0.1)

  ## Returns
  - :ok if no significant degradation detected
  - {:error, degradation_details} if quality degradation exceeds thresholds
  """
  @spec prevent_quality_degradation(QualityScore.t(), QualityScore.t(), float()) :: :ok | {:error, map()}
  def prevent_quality_degradation(%QualityScore{} = original, %QualityScore{} = refined, max_degradation_threshold \\ 0.1) do
    degradation_analysis = %{
      overall: original.overall - refined.overall,
      completeness: original.completeness - refined.completeness,
      accuracy: original.accuracy - refined.accuracy,
      consistency: original.consistency - refined.consistency,
      usability: original.usability - refined.usability
    }

    significant_degradations = degradation_analysis
    |> Enum.filter(fn {_dimension, degradation} -> degradation > max_degradation_threshold end)
    |> Enum.into(%{})

    if map_size(significant_degradations) == 0 do
      :ok
    else
      {:error, %{
        message: "Significant quality degradation detected",
        degraded_dimensions: significant_degradations,
        threshold: max_degradation_threshold
      }}
    end
  end

  @doc """
  Validates that improvements are meaningful and not just superficial changes.

  Checks for substantial improvements in configuration structure, content quality,
  and practical applicability rather than just minor cosmetic changes.

  ## Parameters
  - original_config: Original domain configuration
  - refined_config: Refined domain configuration

  ## Returns
  - {:ok, meaningfulness_score} where score is 0.0-1.0
  - {:error, reason} if validation fails
  """
  @spec validate_improvement_meaningfulness(map(), map()) :: {:ok, float()} | {:error, String.t()}
  def validate_improvement_meaningfulness(original_config, refined_config)
      when is_map(original_config) and is_map(refined_config) do

    structural_changes = analyze_structural_changes(original_config, refined_config)
    content_changes = analyze_content_changes(original_config, refined_config)
    functional_changes = analyze_functional_changes(original_config, refined_config)

    meaningfulness_score = calculate_meaningfulness_score(structural_changes, content_changes, functional_changes)

    {:ok, meaningfulness_score}
  end

  @doc """
  Generates improvement recommendations based on validation results.

  ## Parameters
  - validation_result: Result from validate_improvements/3
  - original_config: Original configuration for context
  - refined_config: Refined configuration for context

  ## Returns
  - List of specific recommendations for further improvement
  """
  @spec generate_improvement_recommendations(improvement_result(), map(), map()) :: [String.t()]
  def generate_improvement_recommendations(validation_result, original_config, refined_config)
      when is_map(validation_result) and is_map(original_config) and is_map(refined_config) do

    recommendations = []

    # Add recommendations based on validation results
    recommendations = if validation_result.is_improvement do
      ["Accept refinement - quality improvement of #{Float.round(validation_result.quality_change * 100, 2)}% detected" | recommendations]
    else
      ["Consider additional refinement - current improvement (#{Float.round(validation_result.quality_change * 100, 2)}%) below threshold" | recommendations]
    end

    # Add dimension-specific recommendations
    recommendations = recommendations ++ generate_dimension_recommendations(validation_result)

    # Add error-based recommendations
    recommendations = recommendations ++ generate_error_recommendations(validation_result.validation_errors)

    # Add configuration-specific recommendations
    recommendations ++ generate_configuration_recommendations(original_config, refined_config)
  end

  # Private functions for improvement analysis

  defp analyze_quality_improvements(original_quality, refined_quality) do
    QualityScore.compare_quality_scores(original_quality, refined_quality)
  end

  defp validate_configuration_integrity(original_config, refined_config) do
    errors = []

    # Check that essential structure is preserved
    errors = if missing_essential_fields?(refined_config) do
      ["Refined configuration missing essential fields" | errors]
    else
      errors
    end

    # Check that signal fields are still valid
    errors = if invalid_signal_field_changes?(original_config, refined_config) do
      ["Invalid signal field modifications detected" | errors]
    else
      errors
    end

    # Check that patterns maintain logical consistency
    errors = if patterns_lost_consistency?(refined_config) do
      ["Pattern logical consistency compromised" | errors]
    else
      errors
    end

    # Check for excessive changes that might indicate over-refinement
    errors = if excessive_changes_detected?(original_config, refined_config) do
      ["Excessive changes detected - refinement may have gone too far" | errors]
    else
      errors
    end

    errors
  end

  defp missing_essential_fields?(config) do
    essential_fields = ["domain", "signals_fields", "patterns"]
    not Enum.all?(essential_fields, &Map.has_key?(config, &1))
  end

  defp invalid_signal_field_changes?(original_config, refined_config) do
    original_fields = MapSet.new(original_config["signals_fields"] || [])
    refined_fields = MapSet.new(refined_config["signals_fields"] || [])

    # Check if more than 50% of fields were removed (might be too aggressive)
    removed_count = MapSet.size(MapSet.difference(original_fields, refined_fields))
    original_count = MapSet.size(original_fields)

    original_count > 0 and (removed_count / original_count) > 0.5
  end

  defp patterns_lost_consistency?(config) do
    patterns = config["patterns"] || []

    # Check if patterns have contradictory conditions
    Enum.any?(patterns, fn pattern ->
      use_when = pattern["use_when"] || []
      avoid_when = pattern["avoid_when"] || []

      # Simple check for direct contradictions
      Enum.any?(use_when, fn use_condition ->
        Enum.any?(avoid_when, fn avoid_condition ->
          use_condition["field"] == avoid_condition["field"] and
          use_condition["op"] == avoid_condition["op"] and
          use_condition["value"] == avoid_condition["value"]
        end)
      end)
    end)
  end

  defp excessive_changes_detected?(original_config, refined_config) do
    # Calculate change percentage across different aspects
    field_change_ratio = calculate_field_change_ratio(original_config, refined_config)
    pattern_change_ratio = calculate_pattern_change_ratio(original_config, refined_config)

    # If more than 80% of content changed, it might be excessive
    (field_change_ratio + pattern_change_ratio) / 2 > 0.8
  end

  defp calculate_field_change_ratio(original_config, refined_config) do
    original_fields = MapSet.new(original_config["signals_fields"] || [])
    refined_fields = MapSet.new(refined_config["signals_fields"] || [])

    if MapSet.size(original_fields) == 0 do
      0.0
    else
      changed_fields = MapSet.union(
        MapSet.difference(original_fields, refined_fields),
        MapSet.difference(refined_fields, original_fields)
      )
      MapSet.size(changed_fields) / MapSet.size(original_fields)
    end
  end

  defp calculate_pattern_change_ratio(original_config, refined_config) do
    original_patterns = original_config["patterns"] || []
    refined_patterns = refined_config["patterns"] || []

    if length(original_patterns) == 0 do
      0.0
    else
      original_ids = MapSet.new(Enum.map(original_patterns, & &1["id"]))
      refined_ids = MapSet.new(Enum.map(refined_patterns, & &1["id"]))

      changed_patterns = MapSet.union(
        MapSet.difference(original_ids, refined_ids),
        MapSet.difference(refined_ids, original_ids)
      )
      MapSet.size(changed_patterns) / length(original_patterns)
    end
  end

  defp determine_recommendation(improvement_analysis, validation_errors, min_threshold) do
    cond do
      length(validation_errors) > 0 -> :reject
      improvement_analysis.overall_improvement >= min_threshold -> :accept
      improvement_analysis.overall_improvement > 0 -> :conditional
      true -> :reject
    end
  end

  # Private functions for tracking improvement metrics

  defp count_successful_improvements(history) do
    Enum.count(history, & &1.is_improvement)
  end

  defp calculate_average_quality_gain(history) do
    if length(history) == 0 do
      0.0
    else
      total_gain = Enum.sum(Enum.map(history, & &1.quality_change))
      total_gain / length(history)
    end
  end

  defp identify_most_improved_dimensions(history) do
    history
    |> Enum.flat_map(& &1.improved_dimensions)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_dimension, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {dimension, _count} -> dimension end)
  end

  defp identify_common_degradation_areas(history) do
    history
    |> Enum.flat_map(& &1.degraded_dimensions)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_dimension, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {dimension, _count} -> dimension end)
  end

  defp calculate_improvement_trend(history) do
    if length(history) < 3 do
      :insufficient_data
    else
      recent_improvements = history |> Enum.take(5) |> Enum.map(& &1.quality_change)
      older_improvements = history |> Enum.drop(5) |> Enum.take(5) |> Enum.map(& &1.quality_change)

      if length(older_improvements) == 0 do
        :insufficient_data
      else
        recent_avg = Enum.sum(recent_improvements) / length(recent_improvements)
        older_avg = Enum.sum(older_improvements) / length(older_improvements)

        cond do
          recent_avg > older_avg + 0.02 -> :improving
          recent_avg < older_avg - 0.02 -> :declining
          true -> :stable
        end
      end
    end
  end

  defp calculate_success_rate(history) do
    if length(history) == 0 do
      0.0
    else
      successful_count = count_successful_improvements(history)
      successful_count / length(history)
    end
  end

  # Private functions for meaningfulness validation

  defp analyze_structural_changes(original_config, refined_config) do
    %{
      fields_added: count_added_fields(original_config, refined_config),
      fields_removed: count_removed_fields(original_config, refined_config),
      patterns_added: count_added_patterns(original_config, refined_config),
      patterns_removed: count_removed_patterns(original_config, refined_config),
      sections_added: count_added_sections(original_config, refined_config)
    }
  end

  defp analyze_content_changes(original_config, refined_config) do
    %{
      domain_name_changed: original_config["domain"] != refined_config["domain"],
      descriptions_enhanced: descriptions_were_enhanced?(original_config, refined_config),
      pattern_summaries_improved: pattern_summaries_improved?(original_config, refined_config)
    }
  end

  defp analyze_functional_changes(original_config, refined_config) do
    %{
      pattern_logic_improved: pattern_logic_was_improved?(original_config, refined_config),
      field_usage_optimized: field_usage_was_optimized?(original_config, refined_config),
      consistency_enhanced: consistency_was_enhanced?(original_config, refined_config)
    }
  end

  defp calculate_meaningfulness_score(structural, content, functional) do
    # Weight different types of changes
    structural_score = calculate_structural_score(structural) * 0.3
    content_score = calculate_content_score(content) * 0.3
    functional_score = calculate_functional_score(functional) * 0.4

    structural_score + content_score + functional_score
  end

  defp calculate_structural_score(changes) do
    # Score based on meaningful structural additions/improvements
    score = 0.0
    score = score + min(changes.fields_added * 0.1, 0.3)
    score = score + min(changes.patterns_added * 0.2, 0.4)
    score = score + min(changes.sections_added * 0.15, 0.3)

    # Penalize excessive removals
    score = score - min(changes.fields_removed * 0.05, 0.2)
    score = score - min(changes.patterns_removed * 0.1, 0.3)

    max(0.0, min(1.0, score))
  end

  defp calculate_content_score(changes) do
    score = 0.0
    score = if changes.domain_name_changed, do: score + 0.2, else: score
    score = if changes.descriptions_enhanced, do: score + 0.4, else: score
    score = if changes.pattern_summaries_improved, do: score + 0.4, else: score

    min(1.0, score)
  end

  defp calculate_functional_score(changes) do
    score = 0.0
    score = if changes.pattern_logic_improved, do: score + 0.4, else: score
    score = if changes.field_usage_optimized, do: score + 0.3, else: score
    score = if changes.consistency_enhanced, do: score + 0.3, else: score

    min(1.0, score)
  end

  # Helper functions for change analysis

  defp count_added_fields(original, refined) do
    original_fields = MapSet.new(original["signals_fields"] || [])
    refined_fields = MapSet.new(refined["signals_fields"] || [])
    MapSet.size(MapSet.difference(refined_fields, original_fields))
  end

  defp count_removed_fields(original, refined) do
    original_fields = MapSet.new(original["signals_fields"] || [])
    refined_fields = MapSet.new(refined["signals_fields"] || [])
    MapSet.size(MapSet.difference(original_fields, refined_fields))
  end

  defp count_added_patterns(original, refined) do
    original_ids = MapSet.new(Enum.map(original["patterns"] || [], & &1["id"]))
    refined_ids = MapSet.new(Enum.map(refined["patterns"] || [], & &1["id"]))
    MapSet.size(MapSet.difference(refined_ids, original_ids))
  end

  defp count_removed_patterns(original, refined) do
    original_ids = MapSet.new(Enum.map(original["patterns"] || [], & &1["id"]))
    refined_ids = MapSet.new(Enum.map(refined["patterns"] || [], & &1["id"]))
    MapSet.size(MapSet.difference(original_ids, refined_ids))
  end

  defp count_added_sections(original, refined) do
    original_keys = MapSet.new(Map.keys(original))
    refined_keys = MapSet.new(Map.keys(refined))
    MapSet.size(MapSet.difference(refined_keys, original_keys))
  end

  defp descriptions_were_enhanced?(original, refined) do
    original_desc_length = String.length(original["description"] || "")
    refined_desc_length = String.length(refined["description"] || "")
    refined_desc_length > original_desc_length + 10
  end

  defp pattern_summaries_improved?(original, refined) do
    original_patterns = original["patterns"] || []
    refined_patterns = refined["patterns"] || []

    original_summary_length = original_patterns |> Enum.map(& String.length(&1["summary"] || "")) |> Enum.sum()
    refined_summary_length = refined_patterns |> Enum.map(& String.length(&1["summary"] || "")) |> Enum.sum()

    refined_summary_length > original_summary_length + 20
  end

  defp pattern_logic_was_improved?(original, refined) do
    # Check if patterns have more complete or better structured conditions
    original_condition_count = count_total_conditions(original["patterns"] || [])
    refined_condition_count = count_total_conditions(refined["patterns"] || [])

    refined_condition_count > original_condition_count
  end

  defp count_total_conditions(patterns) do
    patterns
    |> Enum.map(fn pattern ->
      use_when_count = length(pattern["use_when"] || [])
      avoid_when_count = length(pattern["avoid_when"] || [])
      use_when_count + avoid_when_count
    end)
    |> Enum.sum()
  end

  defp field_usage_was_optimized?(original, refined) do
    # Check if field usage in patterns improved
    original_usage = calculate_field_usage_ratio(original)
    refined_usage = calculate_field_usage_ratio(refined)

    refined_usage > original_usage + 0.1
  end

  defp calculate_field_usage_ratio(config) do
    signals_fields = config["signals_fields"] || []
    patterns = config["patterns"] || []

    if length(signals_fields) == 0 do
      0.0
    else
      used_fields = patterns
      |> Enum.flat_map(fn pattern ->
        conditions = (pattern["use_when"] || []) ++ (pattern["avoid_when"] || [])
        Enum.map(conditions, & &1["field"])
      end)
      |> Enum.uniq()

      length(used_fields) / length(signals_fields)
    end
  end

  defp consistency_was_enhanced?(original, refined) do
    # Simple heuristic: check if refined config has fewer validation errors
    original_errors = validate_configuration_integrity(original, original)
    refined_errors = validate_configuration_integrity(refined, refined)

    length(refined_errors) < length(original_errors)
  end

  # Private functions for generating recommendations

  defp generate_dimension_recommendations(validation_result) do
    recommendations = []

    recommendations = if "completeness" in validation_result.degraded_dimensions do
      ["Focus on improving completeness - ensure all necessary configuration sections are present" | recommendations]
    else
      recommendations
    end

    recommendations = if "accuracy" in validation_result.degraded_dimensions do
      ["Address accuracy concerns - review pattern logic and domain alignment" | recommendations]
    else
      recommendations
    end

    recommendations = if "consistency" in validation_result.degraded_dimensions do
      ["Improve consistency - ensure internal coherence across configuration sections" | recommendations]
    else
      recommendations
    end

    if "usability" in validation_result.degraded_dimensions do
      ["Enhance usability - focus on practical applicability and user experience" | recommendations]
    else
      recommendations
    end
  end

  defp generate_error_recommendations(validation_errors) do
    Enum.map(validation_errors, fn error ->
      case error do
        "Refined configuration missing essential fields" ->
          "Restore missing essential fields (domain, signals_fields, patterns)"
        "Invalid signal field modifications detected" ->
          "Review signal field changes - avoid removing more than 50% of fields"
        "Pattern logical consistency compromised" ->
          "Fix pattern contradictions - ensure use_when and avoid_when don't conflict"
        "Excessive changes detected - refinement may have gone too far" ->
          "Consider more conservative refinement approach"
        _ ->
          "Address validation error: #{error}"
      end
    end)
  end

  defp generate_configuration_recommendations(_original_config, refined_config) do
    recommendations = []

    # Check for specific improvement opportunities
    refined_pattern_count = length(refined_config["patterns"] || [])

    recommendations = cond do
      refined_pattern_count < 2 ->
        ["Consider adding more decision patterns for better coverage" | recommendations]
      refined_pattern_count > 8 ->
        ["Consider consolidating patterns to improve usability" | recommendations]
      true -> recommendations
    end

    # Check field count
    refined_field_count = length(refined_config["signals_fields"] || [])

    recommendations = cond do
      refined_field_count < 3 ->
        ["Add more signal fields to improve decision granularity" | recommendations]
      refined_field_count > 12 ->
        ["Consider reducing signal fields to essential ones only" | recommendations]
      true -> recommendations
    end

    recommendations
  end
end
