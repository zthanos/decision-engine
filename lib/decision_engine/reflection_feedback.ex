defmodule DecisionEngine.ReflectionFeedback do
  @moduledoc """
  Implements comprehensive feedback generation for domain configuration improvement.

  This module creates specific, actionable improvement recommendations with priority-based
  ordering to guide the refinement process effectively.
  """

  @type t :: %__MODULE__{
    signal_field_suggestions: [String.t()],
    pattern_improvements: [String.t()],
    description_enhancements: [String.t()],
    structural_recommendations: [String.t()],
    priority_areas: [String.t()]
  }

  defstruct [
    :signal_field_suggestions,
    :pattern_improvements,
    :description_enhancements,
    :structural_recommendations,
    :priority_areas
  ]

  @doc """
  Generates comprehensive feedback based on evaluation results and quality scores.

  Creates specific, actionable recommendations across all quality dimensions with
  priority ordering based on impact potential.

  ## Parameters
  - evaluation_results: Results from ReflectionAgent.evaluate_configuration/1
  - quality_score: QualityScore struct from quality assessment

  ## Returns
  - ReflectionFeedback struct with categorized improvement recommendations
  """
  @spec generate_feedback(map(), DecisionEngine.QualityScore.t()) :: t()
  def generate_feedback(evaluation_results, quality_score) when is_map(evaluation_results) do
    signal_suggestions = generate_signal_field_suggestions(evaluation_results.signal_fields)
    pattern_improvements = generate_pattern_improvements(evaluation_results.decision_patterns)
    description_enhancements = generate_description_enhancements(evaluation_results.domain_description)
    structural_recommendations = generate_structural_recommendations(evaluation_results.overall_structure)

    priority_areas = determine_priority_areas(quality_score, evaluation_results)

    %__MODULE__{
      signal_field_suggestions: signal_suggestions,
      pattern_improvements: pattern_improvements,
      description_enhancements: description_enhancements,
      structural_recommendations: structural_recommendations,
      priority_areas: priority_areas
    }
  end

  @doc """
  Filters feedback to focus on high-priority improvements only.

  ## Parameters
  - feedback: ReflectionFeedback struct
  - max_suggestions_per_category: Maximum suggestions per category (default 3)

  ## Returns
  - Filtered ReflectionFeedback with prioritized suggestions
  """
  @spec prioritize_feedback(t(), integer()) :: t()
  def prioritize_feedback(%__MODULE__{} = feedback, max_suggestions_per_category \\ 3) do
    %{feedback |
      signal_field_suggestions: Enum.take(feedback.signal_field_suggestions, max_suggestions_per_category),
      pattern_improvements: Enum.take(feedback.pattern_improvements, max_suggestions_per_category),
      description_enhancements: Enum.take(feedback.description_enhancements, max_suggestions_per_category),
      structural_recommendations: Enum.take(feedback.structural_recommendations, max_suggestions_per_category)
    }
  end

  @doc """
  Converts feedback to a flat list of actionable items with priority scores.

  ## Parameters
  - feedback: ReflectionFeedback struct

  ## Returns
  - List of maps with :suggestion, :category, and :priority keys
  """
  @spec to_actionable_items(t()) :: [map()]
  def to_actionable_items(%__MODULE__{} = feedback) do
    items = []

    # Add signal field suggestions with high priority
    items = items ++ Enum.with_index(feedback.signal_field_suggestions)
    |> Enum.map(fn {suggestion, index} ->
      %{
        suggestion: suggestion,
        category: "signal_fields",
        priority: calculate_priority("signal_fields", index, feedback.priority_areas)
      }
    end)

    # Add pattern improvements
    pattern_items = Enum.with_index(feedback.pattern_improvements)
    |> Enum.map(fn {suggestion, index} ->
      %{
        suggestion: suggestion,
        category: "patterns",
        priority: calculate_priority("patterns", index, feedback.priority_areas)
      }
    end)
    items = items ++ pattern_items

    # Add description enhancements
    description_items = Enum.with_index(feedback.description_enhancements)
    |> Enum.map(fn {suggestion, index} ->
      %{
        suggestion: suggestion,
        category: "description",
        priority: calculate_priority("description", index, feedback.priority_areas)
      }
    end)
    items = items ++ description_items

    # Add structural recommendations
    structural_items = Enum.with_index(feedback.structural_recommendations)
    |> Enum.map(fn {suggestion, index} ->
      %{
        suggestion: suggestion,
        category: "structure",
        priority: calculate_priority("structure", index, feedback.priority_areas)
      }
    end)
    items = items ++ structural_items

    # Sort by priority (higher priority first)
    Enum.sort_by(items, & &1.priority, :desc)
  end

  @doc """
  Checks if feedback contains any actionable suggestions.

  ## Parameters
  - feedback: ReflectionFeedback struct

  ## Returns
  - true if there are actionable suggestions, false otherwise
  """
  @spec has_actionable_suggestions?(t()) :: boolean()
  def has_actionable_suggestions?(%__MODULE__{} = feedback) do
    length(feedback.signal_field_suggestions) > 0 or
    length(feedback.pattern_improvements) > 0 or
    length(feedback.description_enhancements) > 0 or
    length(feedback.structural_recommendations) > 0
  end

  # Private functions for generating category-specific feedback

  defp generate_signal_field_suggestions(signal_evaluation) do
    suggestions = []

    # Relevance-based suggestions
    suggestions = if signal_evaluation.relevance_score < 0.7 do
      unused_fields = signal_evaluation.unused_fields
      if length(unused_fields) > 0 do
        ["Remove unused signal fields: #{Enum.join(unused_fields, ", ")}" | suggestions]
      else
        suggestions
      end
    else
      suggestions
    end

    # Coverage-based suggestions
    suggestions = if signal_evaluation.coverage_completeness < 0.6 do
      case signal_evaluation.field_count do
        count when count < 3 ->
          ["Add more signal fields to improve decision coverage - consider fields like 'complexity', 'budget', 'timeline'" | suggestions]
        count when count > 10 ->
          ["Consider consolidating signal fields - #{count} fields may be too many for effective decision making" | suggestions]
        _ ->
          ["Enhance signal field coverage by adding fields that better represent the decision space" | suggestions]
      end
    else
      suggestions
    end

    # Naming consistency suggestions
    suggestions = if signal_evaluation.naming_consistency < 0.8 do
      ["Improve signal field naming - use consistent snake_case format and descriptive names" | suggestions]
    else
      suggestions
    end

    # Field utilization suggestions
    if signal_evaluation.relevance_score < 0.5 and length(signal_evaluation.unused_fields) > 2 do
      ["Consider redesigning signal fields to better align with decision patterns" | suggestions]
    else
      suggestions
    end
  end

  defp generate_pattern_improvements(pattern_evaluation) do
    suggestions = []

    # Logical consistency improvements
    suggestions = if pattern_evaluation.logical_consistency < 0.8 do
      ["Review pattern conditions for logical contradictions - ensure use_when and avoid_when don't conflict" | suggestions]
    else
      suggestions
    end

    # Mutual exclusivity improvements
    suggestions = if pattern_evaluation.mutual_exclusivity < 0.7 do
      ["Improve pattern differentiation - ensure patterns have distinct outcomes and non-overlapping conditions" | suggestions]
    else
      suggestions
    end

    # Practical applicability improvements
    suggestions = if pattern_evaluation.practical_applicability < 0.8 do
      ["Enhance pattern completeness - ensure all patterns have realistic, actionable conditions" | suggestions]
    else
      suggestions
    end

    # Pattern count suggestions
    suggestions = case pattern_evaluation.pattern_count do
      count when count < 2 ->
        ["Add more decision patterns to provide comprehensive coverage of the domain" | suggestions]
      count when count > 8 ->
        ["Consider consolidating patterns - #{count} patterns may be too complex for users" | suggestions]
      _ -> suggestions
    end

    # Complexity distribution suggestions
    complexity = pattern_evaluation.complexity_distribution
    cond do
      complexity.simple > 0.9 ->
        ["Add more sophisticated patterns with multiple conditions for nuanced decision making" | suggestions]
      complexity.complex > 0.5 ->
        ["Simplify overly complex patterns to improve usability" | suggestions]
      true -> suggestions
    end
  end

  defp generate_description_enhancements(description_evaluation) do
    suggestions = []

    # Clarity improvements
    suggestions = if description_evaluation.clarity_score < 0.7 do
      ["Improve domain name clarity - use descriptive, professional naming conventions" | suggestions]
    else
      suggestions
    end

    # Accuracy improvements
    suggestions = if description_evaluation.accuracy_score < 0.7 do
      ["Enhance description accuracy - ensure domain name and patterns align with business objectives" | suggestions]
    else
      suggestions
    end

    # Alignment improvements
    if description_evaluation.alignment_score < 0.6 do
      ["Improve alignment between domain description and signal fields/patterns" | suggestions]
    else
      suggestions
    end
  end

  defp generate_structural_recommendations(structure_evaluation) do
    suggestions = []

    # Completeness recommendations
    suggestions = if structure_evaluation.completeness_score < 0.8 do
      ["Add missing configuration sections - consider adding metadata, version, or description fields" | suggestions]
    else
      suggestions
    end

    # Coherence recommendations
    suggestions = if structure_evaluation.coherence_score < 0.7 do
      ["Improve internal consistency - ensure all sections work together cohesively" | suggestions]
    else
      suggestions
    end

    # Usability recommendations
    if structure_evaluation.usability_score < 0.7 do
      ["Enhance overall usability - focus on practical applicability and clear organization" | suggestions]
    else
      suggestions
    end
  end

  defp determine_priority_areas(quality_score, evaluation_results) do
    # Calculate priority based on quality scores and improvement potential
    area_scores = %{
      "signal_fields" => quality_score.completeness * 0.6 + quality_score.accuracy * 0.4,
      "patterns" => quality_score.consistency * 0.5 + quality_score.usability * 0.5,
      "description" => quality_score.accuracy * 0.7 + quality_score.usability * 0.3,
      "structure" => quality_score.completeness * 0.4 + quality_score.consistency * 0.6
    }

    # Add evaluation-specific factors
    adjusted_scores = area_scores
    |> Map.put("signal_fields", area_scores["signal_fields"] * evaluation_results.signal_fields.relevance_score)
    |> Map.put("patterns", area_scores["patterns"] * evaluation_results.decision_patterns.logical_consistency)
    |> Map.put("description", area_scores["description"] * evaluation_results.domain_description.clarity_score)
    |> Map.put("structure", area_scores["structure"] * evaluation_results.overall_structure.coherence_score)

    # Sort by lowest scores (highest priority for improvement)
    adjusted_scores
    |> Enum.sort_by(fn {_area, score} -> score end)
    |> Enum.map(fn {area, _score} -> area end)
  end

  defp calculate_priority(category, index, priority_areas) do
    # Base priority decreases with index (first suggestions are higher priority)
    base_priority = 10 - index

    # Boost priority if category is in priority areas
    category_boost = case Enum.find_index(priority_areas, &(&1 == category || String.contains?(&1, category))) do
      nil -> 0
      priority_index -> 5 - priority_index  # Earlier in priority list = higher boost
    end

    base_priority + category_boost
  end
end
