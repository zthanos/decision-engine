defmodule DecisionEngine.QualityScore do
  @moduledoc """
  Implements weighted quality scoring for domain configurations.

  This module provides comprehensive quality assessment using weighted metrics:
  - Completeness (30%): Coverage of domain requirements
  - Accuracy (25%): Correctness of extracted rules
  - Consistency (25%): Internal logical coherence
  - Usability (20%): Practical applicability
  """

  @type t :: %__MODULE__{
    overall: float(),
    completeness: float(),
    accuracy: float(),
    consistency: float(),
    usability: float(),
    detailed_feedback: [String.t()]
  }

  defstruct [
    :overall,
    :completeness,
    :accuracy,
    :consistency,
    :usability,
    :detailed_feedback
  ]

  # Quality dimension weights as specified in requirements
  @completeness_weight 0.30
  @accuracy_weight 0.25
  @consistency_weight 0.25
  @usability_weight 0.20

  @doc """
  Calculates weighted quality scores for a domain configuration.

  Uses evaluation results from ReflectionAgent to compute weighted quality metrics
  according to the specified weights: completeness (30%), accuracy (25%),
  consistency (25%), usability (20%).

  ## Parameters
  - evaluation_results: Results from ReflectionAgent.evaluate_configuration/1

  ## Returns
  - QualityScore struct with calculated scores and detailed feedback
  """
  @spec calculate_quality_score(map()) :: t()
  def calculate_quality_score(evaluation_results) when is_map(evaluation_results) do
    completeness = calculate_completeness_score(evaluation_results)
    accuracy = calculate_accuracy_score(evaluation_results)
    consistency = calculate_consistency_score(evaluation_results)
    usability = calculate_usability_score(evaluation_results)

    overall = calculate_weighted_overall(completeness, accuracy, consistency, usability)

    detailed_feedback = generate_detailed_feedback(
      completeness, accuracy, consistency, usability, evaluation_results
    )

    %__MODULE__{
      overall: overall,
      completeness: completeness,
      accuracy: accuracy,
      consistency: consistency,
      usability: usability,
      detailed_feedback: detailed_feedback
    }
  end

  @doc """
  Compares two quality scores and calculates improvement metrics.

  ## Parameters
  - original: QualityScore struct for original configuration
  - refined: QualityScore struct for refined configuration

  ## Returns
  - Map containing improvement percentages and analysis
  """
  @spec compare_quality_scores(t(), t()) :: map()
  def compare_quality_scores(%__MODULE__{} = original, %__MODULE__{} = refined) do
    %{
      overall_improvement: calculate_improvement_percentage(original.overall, refined.overall),
      completeness_improvement: calculate_improvement_percentage(original.completeness, refined.completeness),
      accuracy_improvement: calculate_improvement_percentage(original.accuracy, refined.accuracy),
      consistency_improvement: calculate_improvement_percentage(original.consistency, refined.consistency),
      usability_improvement: calculate_improvement_percentage(original.usability, refined.usability),
      improved_dimensions: identify_improved_dimensions(original, refined),
      degraded_dimensions: identify_degraded_dimensions(original, refined)
    }
  end

  @doc """
  Validates that a quality score represents an improvement over the original.

  ## Parameters
  - original: Original QualityScore
  - refined: Refined QualityScore
  - min_improvement_threshold: Minimum improvement required (default 0.05)

  ## Returns
  - true if refined score represents meaningful improvement, false otherwise
  """
  @spec is_improvement?(t(), t(), float()) :: boolean()
  def is_improvement?(%__MODULE__{} = original, %__MODULE__{} = refined, min_improvement_threshold \\ 0.05) do
    improvement = refined.overall - original.overall
    improvement >= min_improvement_threshold
  end

  @doc """
  Returns the quality dimension weights used in scoring.

  ## Returns
  - Map with dimension names and their weights
  """
  @spec get_quality_weights() :: map()
  def get_quality_weights do
    %{
      completeness: @completeness_weight,
      accuracy: @accuracy_weight,
      consistency: @consistency_weight,
      usability: @usability_weight
    }
  end

  # Private functions for calculating individual quality dimensions

  defp calculate_completeness_score(evaluation_results) do
    # Completeness based on structural completeness and signal field coverage
    structure_score = evaluation_results.overall_structure.completeness_score
    coverage_score = evaluation_results.signal_fields.coverage_completeness

    # Weight structural completeness more heavily
    (structure_score * 0.7 + coverage_score * 0.3)
  end

  defp calculate_accuracy_score(evaluation_results) do
    # Accuracy based on description accuracy and pattern logical consistency
    description_accuracy = evaluation_results.domain_description.accuracy_score
    pattern_consistency = evaluation_results.decision_patterns.logical_consistency
    field_relevance = evaluation_results.signal_fields.relevance_score

    # Weighted average of accuracy indicators
    (description_accuracy * 0.4 + pattern_consistency * 0.4 + field_relevance * 0.2)
  end

  defp calculate_consistency_score(evaluation_results) do
    # Consistency based on internal coherence and pattern mutual exclusivity
    structural_coherence = evaluation_results.overall_structure.coherence_score
    pattern_exclusivity = evaluation_results.decision_patterns.mutual_exclusivity
    naming_consistency = evaluation_results.signal_fields.naming_consistency

    # Weighted average of consistency indicators
    (structural_coherence * 0.5 + pattern_exclusivity * 0.3 + naming_consistency * 0.2)
  end

  defp calculate_usability_score(evaluation_results) do
    # Usability based on practical applicability and structural usability
    pattern_applicability = evaluation_results.decision_patterns.practical_applicability
    structural_usability = evaluation_results.overall_structure.usability_score
    description_clarity = evaluation_results.domain_description.clarity_score

    # Weighted average of usability indicators
    (pattern_applicability * 0.5 + structural_usability * 0.3 + description_clarity * 0.2)
  end

  defp calculate_weighted_overall(completeness, accuracy, consistency, usability) do
    completeness * @completeness_weight +
    accuracy * @accuracy_weight +
    consistency * @consistency_weight +
    usability * @usability_weight
  end

  defp generate_detailed_feedback(completeness, accuracy, consistency, usability, evaluation_results) do
    feedback = []

    # Add dimension-specific feedback based on scores
    feedback = if completeness < 0.7 do
      ["Completeness needs improvement - consider adding missing configuration sections and signal fields" | feedback]
    else
      feedback
    end

    feedback = if accuracy < 0.7 do
      ["Accuracy concerns detected - review pattern logic and domain description alignment" | feedback]
    else
      feedback
    end

    feedback = if consistency < 0.7 do
      ["Consistency issues found - ensure internal coherence across all configuration sections" | feedback]
    else
      feedback
    end

    feedback = if usability < 0.7 do
      ["Usability could be enhanced - improve pattern applicability and naming clarity" | feedback]
    else
      feedback
    end

    # Add specific feedback from evaluation results
    feedback ++ extract_specific_feedback(evaluation_results)
  end

  defp extract_specific_feedback(evaluation_results) do
    feedback = []

    # Add signal field specific feedback
    feedback = if evaluation_results.signal_fields.relevance_score < 0.6 do
      unused_count = length(evaluation_results.signal_fields.unused_fields)
      ["#{unused_count} unused signal fields detected" | feedback]
    else
      feedback
    end

    # Add pattern specific feedback
    pattern_count = evaluation_results.decision_patterns.pattern_count
    feedback = if pattern_count < 2 do
      ["Consider adding more decision patterns for better coverage" | feedback]
    else
      feedback
    end

    # Add complexity feedback
    complexity = evaluation_results.decision_patterns.complexity_distribution
    feedback = if complexity.simple > 0.8 do
      ["Patterns may be too simple - consider adding more nuanced conditions" | feedback]
    else
      feedback
    end

    feedback
  end

  defp calculate_improvement_percentage(original, refined) do
    if original == 0.0 do
      if refined > 0.0, do: 100.0, else: 0.0
    else
      ((refined - original) / original) * 100.0
    end
  end

  defp identify_improved_dimensions(original, refined) do
    dimensions = [:completeness, :accuracy, :consistency, :usability]

    dimensions
    |> Enum.filter(fn dimension ->
      original_score = Map.get(original, dimension)
      refined_score = Map.get(refined, dimension)
      refined_score > original_score
    end)
    |> Enum.map(&Atom.to_string/1)
  end

  defp identify_degraded_dimensions(original, refined) do
    dimensions = [:completeness, :accuracy, :consistency, :usability]

    dimensions
    |> Enum.filter(fn dimension ->
      original_score = Map.get(original, dimension)
      refined_score = Map.get(refined, dimension)
      refined_score < original_score
    end)
    |> Enum.map(&Atom.to_string/1)
  end
end
