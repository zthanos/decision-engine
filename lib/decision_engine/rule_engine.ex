# lib/decision_engine/rule_engine.ex
defmodule DecisionEngine.RuleEngine do
  @moduledoc """
  Evaluates decision rules based on extracted signals using domain-agnostic processing.
  
  The RuleEngine processes signals against configuration-driven patterns from any domain,
  supporting generic condition evaluation with operators: in, intersects, not_intersects.
  """

  alias DecisionEngine.Types

  @doc """
  Evaluates signals against rule configuration patterns to determine the best recommendation.
  
  ## Parameters
  
    * `signals` - Map of extracted signals from user scenario
    * `rule_config` - Domain-specific rule configuration containing patterns
  
  ## Returns
  
  A map containing the recommendation result with pattern matching details.
  
  ## Examples
  
      iex> signals = %{"workload_type" => "user_productivity"}
      iex> rule_config = %{"patterns" => [%{"id" => "test", "outcome" => "test_outcome", ...}]}
      iex> DecisionEngine.RuleEngine.evaluate(signals, rule_config)
      %{pattern_id: "test", outcome: "test_outcome", ...}
  """
  @spec evaluate(map(), Types.rule_config()) :: map()
  def evaluate(signals, rule_config) do
    patterns = Map.get(rule_config, "patterns", [])
    
    patterns_with_scores =
      patterns
      |> Enum.map(fn pattern ->
        use_when_conditions = Map.get(pattern, "use_when", [])
        avoid_when_conditions = Map.get(pattern, "avoid_when", [])
        
        use_when_score = evaluate_conditions(use_when_conditions, signals)
        avoid_when_score = evaluate_conditions(avoid_when_conditions, signals)

        # Pattern matches if all use_when conditions pass and no avoid_when conditions match
        match = use_when_score == 1.0 && avoid_when_score == 0.0

        {pattern, match, use_when_score, avoid_when_score}
      end)

    # Find the best matching pattern
    best_match =
      patterns_with_scores
      |> Enum.filter(fn {_pattern, match, _, _} -> match end)
      |> Enum.max_by(fn {pattern, _, _, _} -> Map.get(pattern, "score", 0.0) end, fn -> nil end)

    case best_match do
      {pattern, true, _, _} ->
        %{
          pattern_id: Map.get(pattern, "id"),
          outcome: Map.get(pattern, "outcome"),
          score: Map.get(pattern, "score", 0.0),
          summary: Map.get(pattern, "summary"),
          details: extract_pattern_details(pattern),
          matched: true
        }

      nil ->
        # Fallback: return the pattern with highest partial match
        case patterns_with_scores do
          [] ->
            %{
              pattern_id: nil,
              outcome: "no_recommendation",
              score: 0.0,
              summary: "No patterns available for evaluation",
              details: %{},
              matched: false,
              note: "No patterns found in rule configuration."
            }
          
          _ ->
            {fallback_pattern, _, _use_score, _avoid_score} =
              patterns_with_scores
              |> Enum.max_by(fn {pattern, _, use_score, avoid_score} ->
                pattern_score = Map.get(pattern, "score", 0.0)
                pattern_score * use_score * (1 - avoid_score)
              end)

            %{
              pattern_id: Map.get(fallback_pattern, "id"),
              outcome: Map.get(fallback_pattern, "outcome"),
              score: Map.get(fallback_pattern, "score", 0.0) * 0.5,
              summary: "Partial match: " <> Map.get(fallback_pattern, "summary", ""),
              details: extract_pattern_details(fallback_pattern),
              matched: false,
              note: "No perfect match found. This is a partial recommendation."
            }
        end
    end
  end

  # Extract relevant details from pattern for result structure
  defp extract_pattern_details(pattern) do
    pattern
    |> Map.take(["typical_use_cases", "notes", "recommended_alternatives"])
    |> Enum.into(%{}, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # Evaluate a list of conditions against signals, returning match percentage
  defp evaluate_conditions(conditions, signals) do
    if Enum.empty?(conditions) do
      0.0
    else
      matching_conditions =
        conditions
        |> Enum.count(fn condition ->
          evaluate_condition(condition, signals)
        end)

      matching_conditions / length(conditions)
    end
  end

  # Evaluate a single condition against signals using generic operators
  defp evaluate_condition(condition, signals) when is_map(condition) do
    field = Map.get(condition, "field")
    op = Map.get(condition, "op")
    expected = Map.get(condition, "value")
    
    actual = Map.get(signals, field)
    
    evaluate_operator(op, actual, expected)
  end
  
  # Handle legacy atom-based conditions for backward compatibility
  defp evaluate_condition(%{field: field, op: op, value: expected}, signals) do
    actual = Map.get(signals, field)
    evaluate_operator(op, actual, expected)
  end
  
  defp evaluate_condition(_, _), do: false

  # Generic operator evaluation supporting string and atom operators
  defp evaluate_operator(op, actual, expected) when op in ["in", :in] do
    is_list(expected) && actual in expected
  end

  defp evaluate_operator(op, actual, expected) when op in ["intersects", :intersects] do
    is_list(actual) && is_list(expected) && 
      Enum.any?(actual, fn item -> item in expected end)
  end

  defp evaluate_operator(op, actual, expected) when op in ["not_intersects", :not_intersects] do
    !is_list(actual) || !is_list(expected) || 
      !Enum.any?(actual, fn item -> item in expected end)
  end

  defp evaluate_operator(_, _, _), do: false
end
