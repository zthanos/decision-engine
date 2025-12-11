# lib/decision_engine/rule_engine.ex
defmodule DecisionEngine.RuleEngine do
  @moduledoc """
  Evaluates decision rules based on extracted signals.
  """

  @decision_patterns [
    %{
      id: "power_automate_good_fit",
      outcome: "prefer_power_automate",
      score: 0.9,
      summary: "Use Power Automate as the primary automation platform.",
      use_when: [
        %{field: "workload_type", op: :in, value: ["user_productivity", "event_driven_business_process"]},
        %{field: "primary_users", op: :intersects, value: ["citizen_developers", "business_users"]},
        %{field: "target_systems", op: :intersects, value: ["m365", "dataverse", "dynamics_365", "public_saas"]},
        %{field: "data_volume", op: :in, value: ["very_low", "low", "medium"]},
        %{field: "latency_requirement", op: :in, value: ["human_scale_seconds_minutes"]},
        %{field: "process_pattern", op: :intersects, value: ["approvals", "notifications", "document_flow", "human_workflow", "data_sync"]},
        %{field: "complexity_level", op: :in, value: ["simple", "moderate"]},
        %{field: "connectivity_needs", op: :not_intersects, value: ["private_azure_via_vnet"]}
      ],
      avoid_when: [
        %{field: "availability_requirement", op: :in, value: ["mission_critical"]},
        %{field: "devops_need", op: :in, value: ["full_enterprise_devops"]},
        %{field: "workload_type", op: :in, value: ["data_pipeline"]}
      ],
      typical_use_cases: [
        "Approval workflows on SharePoint / Teams / Outlook",
        "Notification flows based on Microsoft 365 events",
        "Lightweight data sync between Dataverse and SaaS systems",
        "User-driven business processes initiated from Power Apps or M365"
      ]
    },
    %{
      id: "power_automate_possible_but_weaker_fit",
      outcome: "power_automate_possible_with_caveats",
      score: 0.6,
      summary: "Power Automate can be used but may not be ideal; consider Logic Apps or other patterns if complexity grows.",
      use_when: [
        %{field: "workload_type", op: :in, value: ["event_driven_business_process", "system_integration"]},
        %{field: "primary_users", op: :intersects, value: ["business_users", "pro_developers"]},
        %{field: "data_volume", op: :in, value: ["medium"]},
        %{field: "complexity_level", op: :in, value: ["moderate"]}
      ],
      avoid_when: [
        %{field: "connectivity_needs", op: :intersects, value: ["private_azure_via_vnet"]},
        %{field: "availability_requirement", op: :in, value: ["mission_critical"]}
      ],
      notes: [
        "Suitable for PoC or interim solutions, with migration path to Logic Apps if integration complexity increases.",
        "Recommend using managed connectors and limiting fan-out and parallel branches."
      ]
    },
    %{
      id: "prefer_logic_apps_or_other_integration",
      outcome: "avoid_power_automate_use_logic_apps_or_integration_platform",
      score: 0.95,
      summary: "Do not use Power Automate as primary solution; prefer Logic Apps or other integration platform.",
      use_when: [
        %{field: "workload_type", op: :in, value: ["system_integration", "data_pipeline"]},
        %{field: "data_volume", op: :in, value: ["high", "streaming"]},
        %{field: "complexity_level", op: :in, value: ["complex"]},
        %{field: "availability_requirement", op: :in, value: ["high", "mission_critical"]},
        %{field: "devops_need", op: :in, value: ["full_enterprise_devops"]}
      ],
      recommended_alternatives: [
        "Azure Logic Apps + API Management",
        "Azure Functions + Service Bus / Event Grid",
        "Dedicated integration platform (iPaaS) for high-throughput system-to-system flows"
      ]
    },
    %{
      id: "use_power_automate_for_rpa_desktop",
      outcome: "use_power_automate_desktop",
      score: 0.8,
      summary: "Use Power Automate Desktop for RPA-style UI automation on legacy or desktop-only applications.",
      use_when: [
        %{field: "workload_type", op: :in, value: ["rpa_desktop"]},
        %{field: "target_systems", op: :intersects, value: ["on_premises_systems", "line_of_business_api"]},
        %{field: "data_volume", op: :in, value: ["very_low", "low"]}
      ],
      avoid_when: [
        %{field: "data_volume", op: :in, value: ["high", "streaming"]},
        %{field: "complexity_level", op: :in, value: ["complex"]}
      ]
    }
  ]

  def evaluate(signals) do
    patterns_with_scores =
      @decision_patterns
      |> Enum.map(fn pattern ->
        use_when_score = evaluate_conditions(pattern.use_when, signals)
        avoid_when_score = evaluate_conditions(Map.get(pattern, :avoid_when, []), signals)

        # Pattern matches if all use_when conditions pass and no avoid_when conditions match
        match = use_when_score == 1.0 && avoid_when_score == 0.0

        {pattern, match, use_when_score, avoid_when_score}
      end)

    # Find the best matching pattern
    best_match =
      patterns_with_scores
      |> Enum.filter(fn {_pattern, match, _, _} -> match end)
      |> Enum.max_by(fn {pattern, _, _, _} -> pattern.score end, fn -> nil end)

    case best_match do
      {pattern, true, _, _} ->
        %{
          pattern_id: pattern.id,
          outcome: pattern.outcome,
          score: pattern.score,
          summary: pattern.summary,
          details: Map.take(pattern, [:typical_use_cases, :notes, :recommended_alternatives]),
          matched: true
        }

      nil ->
        # Fallback: return the pattern with highest partial match
        {fallback_pattern, _, _use_score, _} =
          patterns_with_scores
          |> Enum.max_by(fn {pattern, _, use_score, avoid_score} ->
            pattern.score * use_score * (1 - avoid_score)
          end)

        %{
          pattern_id: fallback_pattern.id,
          outcome: fallback_pattern.outcome,
          score: fallback_pattern.score * 0.5,
          summary: "Partial match: " <> fallback_pattern.summary,
          details: Map.take(fallback_pattern, [:typical_use_cases, :notes, :recommended_alternatives]),
          matched: false,
          note: "No perfect match found. This is a partial recommendation."
        }
    end
  end

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

  defp evaluate_condition(%{field: field, op: op, value: expected}, signals) do
    actual = Map.get(signals, field)

    case op do
      :in ->
        actual in expected

      :intersects ->
        is_list(actual) && Enum.any?(actual, fn item -> item in expected end)

      :not_intersects ->
        !is_list(actual) || !Enum.any?(actual, fn item -> item in expected end)

      _ ->
        false
    end
  end
end
