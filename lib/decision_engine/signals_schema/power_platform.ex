defmodule DecisionEngine.SignalsSchema.PowerPlatform do
  @moduledoc """
  Signal schema definition for Power Platform domain.
  
  Defines the structure and validation rules for signals extracted from
  user scenarios in the Power Platform decision domain.
  """

  @behaviour DecisionEngine.SignalsSchema.Behaviour

  @schema %{
    "type" => "object",
    "required" => ["workload_type", "primary_users", "trigger_nature"],
    "properties" => %{
      "workload_type" => %{
        "type" => "string",
        "enum" => ["user_productivity", "event_driven_business_process", "system_integration"],
        "description" => "Primary type of workload being automated"
      },
      "primary_users" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["citizen_developers", "business_users", "pro_developers"]
        },
        "description" => "Main user groups who will interact with the solution"
      },
      "trigger_nature" => %{
        "type" => "string",
        "enum" => ["user_action", "m365_event", "business_event", "system_event", "schedule"],
        "description" => "What initiates the automated process"
      },
      "data_sources" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["sharepoint", "excel", "dataverse", "dynamics_365", "outlook", "teams", "external_api"]
        },
        "description" => "Data sources that the solution will interact with"
      },
      "integration_complexity" => %{
        "type" => "string",
        "enum" => ["low", "medium", "high"],
        "description" => "Complexity level of required integrations"
      },
      "availability_requirement" => %{
        "type" => "string",
        "enum" => ["standard_business", "high", "mission_critical"],
        "description" => "Required availability level for the solution"
      },
      "compliance_requirements" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["gdpr", "hipaa", "sox", "strict_data_governance", "none"]
        },
        "description" => "Compliance and governance requirements"
      },
      "expected_volume" => %{
        "type" => "string",
        "enum" => ["very_low", "low", "medium", "high", "very_high"],
        "description" => "Expected transaction or usage volume"
      },
      "user_interaction_pattern" => %{
        "type" => "string",
        "enum" => ["form_based", "dashboard", "mobile", "automated", "approval_workflow"],
        "description" => "How users will interact with the solution"
      }
    }
  }

  @impl DecisionEngine.SignalsSchema.Behaviour
  def schema, do: @schema

  @impl DecisionEngine.SignalsSchema.Behaviour
  def apply_defaults(signals) do
    signals
    |> Map.put_new("workload_type", "event_driven_business_process")
    |> Map.put_new("primary_users", ["business_users"])
    |> Map.put_new("trigger_nature", "business_event")
    |> Map.put_new("data_sources", ["sharepoint"])
    |> Map.put_new("integration_complexity", "low")
    |> Map.put_new("availability_requirement", "standard_business")
    |> Map.put_new("compliance_requirements", ["none"])
    |> Map.put_new("expected_volume", "low")
    |> Map.put_new("user_interaction_pattern", "form_based")
  end
end