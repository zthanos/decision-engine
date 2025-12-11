defmodule DecisionEngine.SignalsSchema do
  @moduledoc """
  Defines the schema for signals extracted from user prompts.
  """

  @schema %{
    "type" => "object",
    "required" => ["workload_type", "primary_users", "trigger_nature"],
    "properties" => %{
      "workload_type" => %{
        "type" => "string",
        "enum" => ["user_productivity", "system_integration", "data_pipeline",
                   "rpa_desktop", "event_driven_business_process"]
      },
      "primary_users" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["citizen_developers", "business_users", "pro_developers",
                     "integration_team", "data_team"]
        }
      },
      "trigger_nature" => %{
        "type" => "string",
        "enum" => ["user_action", "m365_event", "business_event", "system_event", "schedule"]
      },
      "target_systems" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["m365", "dataverse", "dynamics_365", "public_saas",
                     "line_of_business_api", "on_premises_systems", "azure_paas"]
        }
      },
      "connectivity_needs" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["public_internet", "on_prem_via_gateway",
                     "private_azure_via_vnet", "none"]
        }
      },
      "data_volume" => %{
        "type" => "string",
        "enum" => ["very_low", "low", "medium", "high", "streaming"]
      },
      "latency_requirement" => %{
        "type" => "string",
        "enum" => ["human_scale_seconds_minutes", "near_real_time", "sub_second_oltp"]
      },
      "process_pattern" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["approvals", "notifications", "document_flow", "data_sync",
                     "human_workflow", "long_running_business_process",
                     "integration_orchestration"]
        }
      },
      "complexity_level" => %{
        "type" => "string",
        "enum" => ["simple", "moderate", "complex"]
      },
      "availability_requirement" => %{
        "type" => "string",
        "enum" => ["standard_business", "high", "mission_critical"]
      },
      "devops_need" => %{
        "type" => "string",
        "enum" => ["minimal", "basic_almd_solutions", "full_enterprise_devops"]
      },
      "governance_priority" => %{
        "type" => "string",
        "enum" => ["low", "medium", "high"]
      }
    }
  }

  def schema, do: @schema

  def apply_defaults(signals) do
    signals
    |> Map.put_new("workload_type", "event_driven_business_process")
    |> Map.put_new("primary_users", ["business_users"])
    |> Map.put_new("trigger_nature", "business_event")
    |> Map.put_new("target_systems", [])
    |> Map.put_new("connectivity_needs", ["public_internet"])
    |> Map.put_new("data_volume", "low")
    |> Map.put_new("latency_requirement", "human_scale_seconds_minutes")
    |> Map.put_new("process_pattern", [])
    |> Map.put_new("complexity_level", "simple")
    |> Map.put_new("availability_requirement", "standard_business")
    |> Map.put_new("devops_need", "minimal")
    |> Map.put_new("governance_priority", "medium")
  end
end
