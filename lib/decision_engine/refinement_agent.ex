defmodule DecisionEngine.RefinementAgent do
  @moduledoc """
  The RefinementAgent applies improvement suggestions to enhance domain configurations.

  This module implements the refinement capabilities for the agentic reflection pattern,
  taking feedback from the ReflectionAgent and applying specific improvements to create
  enhanced domain configurations.
  """

  alias DecisionEngine.Types
  alias DecisionEngine.ReflectionFeedback

  @doc """
  Applies improvement suggestions to enhance a domain configuration.

  Takes a domain configuration and reflection feedback, then applies the suggested
  improvements to create an enhanced version of the configuration.

  ## Parameters
  - domain_config: The original domain configuration map
  - feedback: ReflectionFeedback struct with improvement suggestions

  ## Returns
  - {:ok, enhanced_config} on successful refinement
  - {:error, reason} if refinement fails
  """
  @spec apply_improvements(map(), ReflectionFeedback.t()) :: {:ok, map()} | {:error, String.t()}
  def apply_improvements(domain_config, %ReflectionFeedback{} = feedback) when is_map(domain_config) do
    with :ok <- Types.validate_rule_config(domain_config) do
      enhanced_config = domain_config
      |> apply_signal_field_improvements(feedback.signal_field_suggestions)
      |> apply_pattern_improvements(feedback.pattern_improvements)
      |> apply_description_enhancements(feedback.description_enhancements)
      |> apply_structural_improvements(feedback.structural_recommendations)

      case Types.validate_rule_config(enhanced_config) do
        :ok -> {:ok, enhanced_config}
        {:error, reason} -> {:error, "Enhanced configuration validation failed: #{reason}"}
      end
    else
      {:error, reason} -> {:error, "Original configuration validation failed: #{reason}"}
    end
  end
  def apply_improvements(_, _), do: {:error, "Invalid input parameters"}

  @doc """
  Optimizes decision patterns by consolidating similar patterns and improving conditions.

  ## Parameters
  - patterns: List of pattern maps to optimize
  - suggestions: List of pattern improvement suggestions

  ## Returns
  - List of optimized patterns
  """
  @spec optimize_patterns([map()], [String.t()]) :: [map()]
  def optimize_patterns(patterns, suggestions) when is_list(patterns) and is_list(suggestions) do
    patterns
    |> consolidate_similar_patterns()
    |> improve_pattern_conditions(suggestions)
    |> ensure_pattern_completeness()
    |> validate_pattern_consistency()
  end

  @doc """
  Enhances signal fields by improving naming, adding missing fields, and removing unused ones.

  ## Parameters
  - signal_fields: List of current signal field names
  - recommendations: List of signal field improvement recommendations
  - patterns: List of patterns to check field usage against

  ## Returns
  - List of enhanced signal fields
  """
  @spec enhance_signal_fields([String.t()], [String.t()], [map()]) :: [String.t()]
  def enhance_signal_fields(signal_fields, recommendations, patterns)
      when is_list(signal_fields) and is_list(recommendations) and is_list(patterns) do
    signal_fields
    |> remove_unused_fields(patterns, recommendations)
    |> improve_field_naming(recommendations)
    |> add_suggested_fields(recommendations)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Enhances domain descriptions for better clarity and alignment.

  ## Parameters
  - domain_config: Current domain configuration
  - enhancements: List of description enhancement suggestions

  ## Returns
  - Enhanced domain configuration with improved descriptions
  """
  @spec enhance_descriptions(map(), [String.t()]) :: map()
  def enhance_descriptions(domain_config, enhancements) when is_map(domain_config) and is_list(enhancements) do
    domain_config
    |> improve_domain_name(enhancements)
    |> add_missing_descriptions(enhancements)
    |> enhance_pattern_summaries(enhancements)
  end

  # Private functions for applying signal field improvements

  defp apply_signal_field_improvements(config, suggestions) do
    current_fields = config["signals_fields"] || []
    patterns = config["patterns"] || []

    enhanced_fields = enhance_signal_fields(current_fields, suggestions, patterns)

    Map.put(config, "signals_fields", enhanced_fields)
  end

  defp remove_unused_fields(signal_fields, patterns, recommendations) do
    # Extract fields that are actually used in patterns
    used_fields = extract_used_fields(patterns)

    # Check if recommendations suggest removing unused fields
    should_remove_unused = Enum.any?(recommendations, &String.contains?(&1, "Remove unused"))

    if should_remove_unused do
      Enum.filter(signal_fields, &(&1 in used_fields))
    else
      signal_fields
    end
  end

  defp extract_used_fields(patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      conditions = (pattern["use_when"] || []) ++ (pattern["avoid_when"] || [])
      Enum.map(conditions, & &1["field"])
    end)
    |> Enum.uniq()
  end

  defp improve_field_naming(signal_fields, recommendations) do
    # Check if recommendations suggest improving naming
    should_improve_naming = Enum.any?(recommendations, &String.contains?(&1, "naming"))

    if should_improve_naming do
      Enum.map(signal_fields, &normalize_field_name/1)
    else
      signal_fields
    end
  end

  defp normalize_field_name(field_name) do
    field_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim_trailing("_")
    |> String.trim_leading("_")
    |> ensure_minimum_length()
  end

  defp ensure_minimum_length(field_name) do
    if String.length(field_name) < 3 do
      field_name <> "_field"
    else
      field_name
    end
  end

  defp add_suggested_fields(signal_fields, recommendations) do
    # Extract suggested new fields from recommendations
    new_fields = extract_suggested_fields(recommendations)
    signal_fields ++ new_fields
  end

  defp extract_suggested_fields(recommendations) do
    recommendations
    |> Enum.flat_map(&extract_fields_from_suggestion/1)
    |> Enum.uniq()
  end

  defp extract_fields_from_suggestion(suggestion) do
    # Look for field suggestions in common patterns
    cond do
      String.contains?(suggestion, "complexity") -> ["complexity"]
      String.contains?(suggestion, "budget") -> ["budget"]
      String.contains?(suggestion, "timeline") -> ["timeline"]
      String.contains?(suggestion, "priority") -> ["priority"]
      String.contains?(suggestion, "risk") -> ["risk_level"]
      String.contains?(suggestion, "performance") -> ["performance_requirement"]
      String.contains?(suggestion, "scalability") -> ["scalability_need"]
      String.contains?(suggestion, "security") -> ["security_level"]
      true -> []
    end
  end

  # Private functions for applying pattern improvements

  defp apply_pattern_improvements(config, suggestions) do
    current_patterns = config["patterns"] || []

    enhanced_patterns = optimize_patterns(current_patterns, suggestions)

    Map.put(config, "patterns", enhanced_patterns)
  end

  defp consolidate_similar_patterns(patterns) do
    # Group patterns by similar outcomes and conditions
    pattern_groups = group_similar_patterns(patterns)

    # Consolidate each group
    Enum.flat_map(pattern_groups, &consolidate_pattern_group/1)
  end

  defp group_similar_patterns(patterns) do
    patterns
    |> Enum.group_by(&get_pattern_signature/1)
    |> Map.values()
  end

  defp get_pattern_signature(pattern) do
    # Create a signature based on outcome and key conditions
    outcome = pattern["outcome"] || ""
    use_when_fields = (pattern["use_when"] || []) |> Enum.map(& &1["field"]) |> Enum.sort()

    {outcome, use_when_fields}
  end

  defp consolidate_pattern_group([single_pattern]), do: [single_pattern]
  defp consolidate_pattern_group(similar_patterns) do
    # If multiple patterns are very similar, merge them
    if should_consolidate_patterns?(similar_patterns) do
      [merge_similar_patterns(similar_patterns)]
    else
      similar_patterns
    end
  end

  defp should_consolidate_patterns?(patterns) do
    # Consolidate if patterns have same outcome and overlapping conditions
    outcomes = patterns |> Enum.map(& &1["outcome"]) |> Enum.uniq()
    length(outcomes) == 1 and length(patterns) > 1
  end

  defp merge_similar_patterns([first_pattern | rest_patterns]) do
    # Merge conditions and take the highest score
    merged_use_when = merge_conditions(Enum.map([first_pattern | rest_patterns], & &1["use_when"] || []))
    merged_avoid_when = merge_conditions(Enum.map([first_pattern | rest_patterns], & &1["avoid_when"] || []))

    max_score = [first_pattern | rest_patterns] |> Enum.map(& &1["score"]) |> Enum.max()

    summaries = [first_pattern | rest_patterns] |> Enum.map(& &1["summary"]) |> Enum.uniq()
    merged_summary = Enum.join(summaries, "; ")

    %{
      "id" => "#{first_pattern["id"]}_consolidated",
      "outcome" => first_pattern["outcome"],
      "score" => max_score,
      "summary" => merged_summary,
      "use_when" => merged_use_when,
      "avoid_when" => merged_avoid_when,
      "typical_use_cases" => merge_use_cases([first_pattern | rest_patterns])
    }
  end

  defp merge_conditions(condition_lists) do
    condition_lists
    |> List.flatten()
    |> Enum.uniq_by(&{&1["field"], &1["op"], &1["value"]})
  end

  defp merge_use_cases(patterns) do
    patterns
    |> Enum.flat_map(& &1["typical_use_cases"] || [])
    |> Enum.uniq()
  end

  defp improve_pattern_conditions(patterns, suggestions) do
    # Apply condition improvements based on suggestions
    should_improve_logic = Enum.any?(suggestions, &String.contains?(&1, "logical"))
    should_improve_exclusivity = Enum.any?(suggestions, &String.contains?(&1, "exclusivity"))

    patterns
    |> maybe_improve_logical_consistency(should_improve_logic)
    |> maybe_improve_mutual_exclusivity(should_improve_exclusivity)
  end

  defp maybe_improve_logical_consistency(patterns, true) do
    Enum.map(patterns, &fix_logical_contradictions/1)
  end
  defp maybe_improve_logical_consistency(patterns, false), do: patterns

  defp fix_logical_contradictions(pattern) do
    use_when = pattern["use_when"] || []
    avoid_when = pattern["avoid_when"] || []

    # Remove contradictory conditions
    cleaned_avoid_when = Enum.reject(avoid_when, fn avoid_condition ->
      Enum.any?(use_when, fn use_condition ->
        conditions_contradict?(use_condition, avoid_condition)
      end)
    end)

    Map.put(pattern, "avoid_when", cleaned_avoid_when)
  end

  defp conditions_contradict?(condition1, condition2) do
    condition1["field"] == condition2["field"] and
    condition1["op"] == condition2["op"] and
    condition1["value"] == condition2["value"]
  end

  defp maybe_improve_mutual_exclusivity(patterns, true) do
    # Ensure patterns have distinct outcomes or conditions
    Enum.map(patterns, &ensure_pattern_distinctiveness(&1, patterns))
  end
  defp maybe_improve_mutual_exclusivity(patterns, false), do: patterns

  defp ensure_pattern_distinctiveness(pattern, all_patterns) do
    # If pattern outcome is too similar to others, modify it slightly
    similar_patterns = Enum.filter(all_patterns, fn other ->
      other["id"] != pattern["id"] and other["outcome"] == pattern["outcome"]
    end)

    if length(similar_patterns) > 0 do
      Map.put(pattern, "outcome", "#{pattern["outcome"]}_variant")
    else
      pattern
    end
  end

  defp ensure_pattern_completeness(patterns) do
    Enum.map(patterns, &ensure_complete_pattern_structure/1)
  end

  defp ensure_complete_pattern_structure(pattern) do
    pattern
    |> ensure_field("id", generate_pattern_id(pattern))
    |> ensure_field("outcome", "default_outcome")
    |> ensure_field("score", 0.5)
    |> ensure_field("summary", "Pattern summary")
    |> ensure_field("use_when", [])
    |> ensure_field("avoid_when", [])
    |> ensure_field("typical_use_cases", ["General use case"])
  end

  defp ensure_field(pattern, field, default_value) do
    if Map.has_key?(pattern, field) and not is_nil(pattern[field]) do
      pattern
    else
      Map.put(pattern, field, default_value)
    end
  end

  defp generate_pattern_id(pattern) do
    outcome = pattern["outcome"] || "pattern"
    timestamp = :os.system_time(:millisecond)
    "#{outcome}_#{timestamp}"
  end

  defp validate_pattern_consistency(patterns) do
    # Ensure all patterns have valid structure
    Enum.filter(patterns, &valid_pattern_structure?/1)
  end

  defp valid_pattern_structure?(pattern) do
    required_fields = ["id", "outcome", "score", "summary", "use_when", "avoid_when"]
    Enum.all?(required_fields, &Map.has_key?(pattern, &1))
  end

  # Private functions for applying description enhancements

  defp apply_description_enhancements(config, enhancements) do
    enhance_descriptions(config, enhancements)
  end

  defp improve_domain_name(config, enhancements) do
    should_improve_name = Enum.any?(enhancements, &String.contains?(&1, "domain name"))

    if should_improve_name do
      current_name = config["domain"] || ""
      improved_name = normalize_domain_name(current_name)
      Map.put(config, "domain", improved_name)
    else
      config
    end
  end

  defp normalize_domain_name(domain_name) do
    domain_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim_trailing("_")
    |> String.trim_leading("_")
    |> ensure_domain_name_length()
  end

  defp ensure_domain_name_length(domain_name) do
    if String.length(domain_name) < 3 do
      domain_name <> "_platform"
    else
      domain_name
    end
  end

  defp add_missing_descriptions(config, enhancements) do
    should_add_descriptions = Enum.any?(enhancements, &String.contains?(&1, "missing"))

    if should_add_descriptions do
      config
      |> Map.put_new("description", "Domain configuration for #{config["domain"]}")
      |> Map.put_new("version", "1.0")
      |> Map.put_new("metadata", %{
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "enhanced_by" => "refinement_agent"
      })
    else
      config
    end
  end

  defp enhance_pattern_summaries(config, enhancements) do
    should_enhance_summaries = Enum.any?(enhancements, &String.contains?(&1, "summary"))

    if should_enhance_summaries do
      patterns = config["patterns"] || []
      enhanced_patterns = Enum.map(patterns, &improve_pattern_summary/1)
      Map.put(config, "patterns", enhanced_patterns)
    else
      config
    end
  end

  defp improve_pattern_summary(pattern) do
    current_summary = pattern["summary"] || ""

    if String.length(current_summary) < 10 do
      outcome = pattern["outcome"] || "recommendation"
      improved_summary = "Recommends #{outcome} based on specific conditions and requirements"
      Map.put(pattern, "summary", improved_summary)
    else
      pattern
    end
  end

  # Private functions for applying structural improvements

  defp apply_structural_improvements(config, recommendations) do
    config
    |> add_missing_structural_elements(recommendations)
    |> improve_configuration_organization(recommendations)
    |> validate_structural_consistency(recommendations)
  end

  defp add_missing_structural_elements(config, recommendations) do
    should_add_elements = Enum.any?(recommendations, &String.contains?(&1, "missing"))

    if should_add_elements do
      config
      |> Map.put_new("version", "1.0")
      |> Map.put_new("description", "Enhanced domain configuration")
      |> Map.put_new("metadata", %{
        "last_updated" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "refinement_applied" => true
      })
    else
      config
    end
  end

  defp improve_configuration_organization(config, recommendations) do
    should_improve_organization = Enum.any?(recommendations, &String.contains?(&1, "organization"))

    if should_improve_organization do
      # Ensure consistent ordering of configuration sections
      %{
        "domain" => config["domain"],
        "description" => config["description"],
        "version" => config["version"],
        "signals_fields" => config["signals_fields"],
        "patterns" => config["patterns"],
        "metadata" => config["metadata"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})
    else
      config
    end
  end

  defp validate_structural_consistency(config, recommendations) do
    should_validate_consistency = Enum.any?(recommendations, &String.contains?(&1, "consistency"))

    if should_validate_consistency do
      # Ensure all referenced fields exist in signals_fields
      signals_fields = MapSet.new(config["signals_fields"] || [])
      patterns = config["patterns"] || []

      validated_patterns = Enum.map(patterns, fn pattern ->
        validate_pattern_field_references(pattern, signals_fields)
      end)

      Map.put(config, "patterns", validated_patterns)
    else
      config
    end
  end

  defp validate_pattern_field_references(pattern, valid_fields) do
    use_when = (pattern["use_when"] || [])
    |> Enum.filter(fn condition ->
      MapSet.member?(valid_fields, condition["field"])
    end)

    avoid_when = (pattern["avoid_when"] || [])
    |> Enum.filter(fn condition ->
      MapSet.member?(valid_fields, condition["field"])
    end)

    pattern
    |> Map.put("use_when", use_when)
    |> Map.put("avoid_when", avoid_when)
  end
end
