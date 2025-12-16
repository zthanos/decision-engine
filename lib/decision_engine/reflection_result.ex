defmodule DecisionEngine.ReflectionResult do
  @moduledoc """
  Represents the complete result structure from a reflection process.

  This module defines the comprehensive result structure that contains both original
  and refined configurations along with quality scores, improvement metrics, and
  reflection metadata for analysis and reporting.
  """

  alias DecisionEngine.QualityScore

  @type quality_scores :: %{
    original: QualityScore.t(),
    refined: QualityScore.t(),
    improvement: float()
  }

  @type reflection_metadata :: %{
    iterations_performed: integer(),
    total_processing_time: integer(),
    improvement_areas: [String.t()],
    feedback_applied: [String.t()],
    termination_reason: atom()
  }

  @type t :: %__MODULE__{
    original_config: map(),
    refined_config: map(),
    quality_scores: quality_scores(),
    reflection_metadata: reflection_metadata()
  }

  defstruct [
    :original_config,
    :refined_config,
    :quality_scores,
    :reflection_metadata
  ]

  @doc """
  Creates a new ReflectionResult with the provided data.

  ## Parameters
  - original_config: The original domain configuration map
  - refined_config: The refined domain configuration map
  - quality_scores: Map containing original, refined, and improvement scores
  - reflection_metadata: Map containing process metadata and metrics

  ## Returns
  - ReflectionResult struct with all provided data
  """
  @spec new(map(), map(), quality_scores(), reflection_metadata()) :: t()
  def new(original_config, refined_config, quality_scores, reflection_metadata)
      when is_map(original_config) and is_map(refined_config) and
           is_map(quality_scores) and is_map(reflection_metadata) do
    %__MODULE__{
      original_config: original_config,
      refined_config: refined_config,
      quality_scores: quality_scores,
      reflection_metadata: reflection_metadata
    }
  end

  @doc """
  Calculates the overall improvement percentage from the reflection process.

  ## Parameters
  - result: ReflectionResult struct

  ## Returns
  - Float representing improvement percentage (can be negative for degradation)
  """
  @spec calculate_improvement_percentage(t()) :: float()
  def calculate_improvement_percentage(%__MODULE__{} = result) do
    original_score = result.quality_scores.original.overall
    refined_score = result.quality_scores.refined.overall

    if original_score == 0.0 do
      if refined_score > 0.0, do: 100.0, else: 0.0
    else
      ((refined_score - original_score) / original_score) * 100.0
    end
  end

  @doc """
  Determines if the reflection process resulted in meaningful improvement.

  ## Parameters
  - result: ReflectionResult struct
  - min_improvement_threshold: Minimum improvement required (default 0.05)

  ## Returns
  - true if improvement is meaningful, false otherwise
  """
  @spec is_meaningful_improvement?(t(), float()) :: boolean()
  def is_meaningful_improvement?(%__MODULE__{} = result, min_improvement_threshold \\ 0.05) do
    result.quality_scores.improvement >= min_improvement_threshold
  end

  @doc """
  Extracts a summary of the reflection process for reporting.

  ## Parameters
  - result: ReflectionResult struct

  ## Returns
  - Map containing key metrics and summary information
  """
  @spec extract_summary(t()) :: map()
  def extract_summary(%__MODULE__{} = result) do
    improvement_percentage = calculate_improvement_percentage(result)

    %{
      domain: result.original_config["domain"],
      iterations_performed: result.reflection_metadata.iterations_performed,
      processing_time_ms: result.reflection_metadata.total_processing_time,
      processing_time_seconds: Float.round(result.reflection_metadata.total_processing_time / 1000, 2),
      quality_improvement: Float.round(result.quality_scores.improvement, 4),
      improvement_percentage: Float.round(improvement_percentage, 2),
      is_improvement: is_meaningful_improvement?(result),
      termination_reason: result.reflection_metadata.termination_reason,
      top_improvement_areas: Enum.take(result.reflection_metadata.improvement_areas, 3),
      original_quality: Float.round(result.quality_scores.original.overall, 3),
      refined_quality: Float.round(result.quality_scores.refined.overall, 3)
    }
  end

  @doc """
  Compares quality scores across different dimensions.

  ## Parameters
  - result: ReflectionResult struct

  ## Returns
  - Map with dimension-wise comparison details
  """
  @spec compare_quality_dimensions(t()) :: map()
  def compare_quality_dimensions(%__MODULE__{} = result) do
    original = result.quality_scores.original
    refined = result.quality_scores.refined

    %{
      completeness: %{
        original: Float.round(original.completeness, 3),
        refined: Float.round(refined.completeness, 3),
        change: Float.round(refined.completeness - original.completeness, 3),
        improved: refined.completeness > original.completeness
      },
      accuracy: %{
        original: Float.round(original.accuracy, 3),
        refined: Float.round(refined.accuracy, 3),
        change: Float.round(refined.accuracy - original.accuracy, 3),
        improved: refined.accuracy > original.accuracy
      },
      consistency: %{
        original: Float.round(original.consistency, 3),
        refined: Float.round(refined.consistency, 3),
        change: Float.round(refined.consistency - original.consistency, 3),
        improved: refined.consistency > original.consistency
      },
      usability: %{
        original: Float.round(original.usability, 3),
        refined: Float.round(refined.usability, 3),
        change: Float.round(refined.usability - original.usability, 3),
        improved: refined.usability > original.usability
      }
    }
  end

  @doc """
  Generates a detailed report of the reflection process.

  ## Parameters
  - result: ReflectionResult struct
  - include_configs: Whether to include full configurations (default false)

  ## Returns
  - Map containing comprehensive reflection report
  """
  @spec generate_detailed_report(t(), boolean()) :: map()
  def generate_detailed_report(%__MODULE__{} = result, include_configs \\ false) do
    summary = extract_summary(result)
    quality_comparison = compare_quality_dimensions(result)

    report = %{
      summary: summary,
      quality_analysis: quality_comparison,
      process_details: %{
        iterations_performed: result.reflection_metadata.iterations_performed,
        total_processing_time: result.reflection_metadata.total_processing_time,
        termination_reason: result.reflection_metadata.termination_reason,
        improvement_areas: result.reflection_metadata.improvement_areas,
        feedback_applied: result.reflection_metadata.feedback_applied
      },
      quality_scores: %{
        original: %{
          overall: result.quality_scores.original.overall,
          completeness: result.quality_scores.original.completeness,
          accuracy: result.quality_scores.original.accuracy,
          consistency: result.quality_scores.original.consistency,
          usability: result.quality_scores.original.usability,
          detailed_feedback: result.quality_scores.original.detailed_feedback
        },
        refined: %{
          overall: result.quality_scores.refined.overall,
          completeness: result.quality_scores.refined.completeness,
          accuracy: result.quality_scores.refined.accuracy,
          consistency: result.quality_scores.refined.consistency,
          usability: result.quality_scores.refined.usability,
          detailed_feedback: result.quality_scores.refined.detailed_feedback
        }
      }
    }

    if include_configs do
      Map.merge(report, %{
        configurations: %{
          original: result.original_config,
          refined: result.refined_config
        }
      })
    else
      report
    end
  end

  @doc """
  Validates that a ReflectionResult has complete and consistent data.

  ## Parameters
  - result: ReflectionResult struct to validate

  ## Returns
  - :ok if validation passes
  - {:error, reason} if validation fails
  """
  @spec validate_result(t()) :: :ok | {:error, String.t()}
  def validate_result(%__MODULE__{} = result) do
    with :ok <- validate_configurations(result),
         :ok <- validate_quality_scores(result),
         :ok <- validate_metadata(result) do
      :ok
    end
  end

  @doc """
  Converts the ReflectionResult to a JSON-serializable format.

  ## Parameters
  - result: ReflectionResult struct
  - include_configs: Whether to include full configurations (default true)

  ## Returns
  - Map suitable for JSON serialization
  """
  @spec to_json_format(t(), boolean()) :: map()
  def to_json_format(%__MODULE__{} = result, include_configs \\ true) do
    base_format = %{
      "quality_scores" => %{
        "original" => quality_score_to_map(result.quality_scores.original),
        "refined" => quality_score_to_map(result.quality_scores.refined),
        "improvement" => result.quality_scores.improvement
      },
      "reflection_metadata" => %{
        "iterations_performed" => result.reflection_metadata.iterations_performed,
        "total_processing_time" => result.reflection_metadata.total_processing_time,
        "improvement_areas" => result.reflection_metadata.improvement_areas,
        "feedback_applied" => result.reflection_metadata.feedback_applied,
        "termination_reason" => Atom.to_string(result.reflection_metadata.termination_reason)
      },
      "summary" => extract_summary(result)
    }

    if include_configs do
      Map.merge(base_format, %{
        "original_config" => result.original_config,
        "refined_config" => result.refined_config
      })
    else
      base_format
    end
  end

  @doc """
  Creates a ReflectionResult from a JSON-formatted map.

  ## Parameters
  - json_data: Map containing JSON-formatted reflection result data

  ## Returns
  - {:ok, reflection_result} on successful parsing
  - {:error, reason} if parsing fails
  """
  @spec from_json_format(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json_format(json_data) when is_map(json_data) do
    try do
      original_config = json_data["original_config"]
      refined_config = json_data["refined_config"]

      quality_scores = %{
        original: map_to_quality_score(json_data["quality_scores"]["original"]),
        refined: map_to_quality_score(json_data["quality_scores"]["refined"]),
        improvement: json_data["quality_scores"]["improvement"]
      }

      metadata = json_data["reflection_metadata"]
      reflection_metadata = %{
        iterations_performed: metadata["iterations_performed"],
        total_processing_time: metadata["total_processing_time"],
        improvement_areas: metadata["improvement_areas"],
        feedback_applied: metadata["feedback_applied"],
        termination_reason: String.to_existing_atom(metadata["termination_reason"])
      }

      result = new(original_config, refined_config, quality_scores, reflection_metadata)

      case validate_result(result) do
        :ok -> {:ok, result}
        {:error, reason} -> {:error, "Invalid result data: #{reason}"}
      end
    rescue
      error -> {:error, "Failed to parse JSON data: #{inspect(error)}"}
    end
  end

  # Private helper functions

  defp validate_configurations(result) do
    with :ok <- DecisionEngine.Types.validate_rule_config(result.original_config),
         :ok <- DecisionEngine.Types.validate_rule_config(result.refined_config) do
      :ok
    else
      {:error, reason} -> {:error, "Configuration validation failed: #{reason}"}
    end
  end

  defp validate_quality_scores(result) do
    original = result.quality_scores.original
    refined = result.quality_scores.refined

    cond do
      not is_struct(original, QualityScore) ->
        {:error, "Original quality score must be a QualityScore struct"}

      not is_struct(refined, QualityScore) ->
        {:error, "Refined quality score must be a QualityScore struct"}

      not is_number(result.quality_scores.improvement) ->
        {:error, "Quality improvement must be a number"}

      true -> :ok
    end
  end

  defp validate_metadata(result) do
    metadata = result.reflection_metadata

    cond do
      not is_integer(metadata.iterations_performed) or metadata.iterations_performed < 0 ->
        {:error, "Iterations performed must be a non-negative integer"}

      not is_integer(metadata.total_processing_time) or metadata.total_processing_time < 0 ->
        {:error, "Total processing time must be a non-negative integer"}

      not is_list(metadata.improvement_areas) ->
        {:error, "Improvement areas must be a list"}

      not is_list(metadata.feedback_applied) ->
        {:error, "Feedback applied must be a list"}

      not is_atom(metadata.termination_reason) ->
        {:error, "Termination reason must be an atom"}

      true -> :ok
    end
  end

  defp quality_score_to_map(%QualityScore{} = score) do
    %{
      "overall" => score.overall,
      "completeness" => score.completeness,
      "accuracy" => score.accuracy,
      "consistency" => score.consistency,
      "usability" => score.usability,
      "detailed_feedback" => score.detailed_feedback
    }
  end

  defp map_to_quality_score(score_map) when is_map(score_map) do
    %QualityScore{
      overall: score_map["overall"],
      completeness: score_map["completeness"],
      accuracy: score_map["accuracy"],
      consistency: score_map["consistency"],
      usability: score_map["usability"],
      detailed_feedback: score_map["detailed_feedback"] || []
    }
  end
end
