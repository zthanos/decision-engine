defmodule DecisionEngine.SignalsSchema.IntegrationPlatform do
  @moduledoc """
  Signal schema definition for Integration Platform domain.
  
  Defines the structure and validation rules for signals extracted from
  user scenarios in the Integration Platform decision domain.
  """

  @behaviour DecisionEngine.SignalsSchema.Behaviour

  @schema %{
    "type" => "object",
    "required" => ["integration_pattern", "message_volume", "reliability_requirements"],
    "properties" => %{
      "integration_pattern" => %{
        "type" => "string",
        "enum" => ["message_queue", "publish_subscribe", "event_streaming", "api_gateway", "rest_api", "workflow", "orchestration", "event_driven", "serverless"],
        "description" => "Primary integration pattern or architecture style"
      },
      "message_volume" => %{
        "type" => "string",
        "enum" => ["very_low", "low", "medium", "high", "very_high"],
        "description" => "Expected volume of messages or transactions"
      },
      "protocol_requirements" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["http", "https", "amqp", "kafka", "mqtt", "websockets", "custom_protocols"]
        },
        "description" => "Required communication protocols"
      },
      "security_requirements" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["authentication", "authorization", "encryption", "rate_limiting", "ip_filtering", "oauth"]
        },
        "description" => "Security and access control requirements"
      },
      "transformation_complexity" => %{
        "type" => "string",
        "enum" => ["low", "medium", "high"],
        "description" => "Complexity of data transformation required"
      },
      "endpoint_count" => %{
        "type" => "string",
        "enum" => ["very_low", "low", "medium", "high"],
        "description" => "Number of systems or endpoints to integrate"
      },
      "reliability_requirements" => %{
        "type" => "string",
        "enum" => ["basic", "high", "mission_critical"],
        "description" => "Required reliability and availability level"
      },
      "monitoring_needs" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["basic_logging", "detailed_analytics", "real_time_monitoring", "alerting", "performance_metrics"]
        },
        "description" => "Monitoring and observability requirements"
      },
      "deployment_model" => %{
        "type" => "string",
        "enum" => ["cloud_native", "hybrid", "on_premises_only", "multi_cloud"],
        "description" => "Preferred deployment model"
      },
      "legacy_system_support" => %{
        "type" => "string",
        "enum" => ["not_required", "required", "critical"],
        "description" => "Need to integrate with legacy systems"
      }
    }
  }

  @impl DecisionEngine.SignalsSchema.Behaviour
  def schema, do: @schema

  @impl DecisionEngine.SignalsSchema.Behaviour
  def apply_defaults(signals) do
    signals
    |> Map.put_new("integration_pattern", "rest_api")
    |> Map.put_new("message_volume", "medium")
    |> Map.put_new("protocol_requirements", ["https"])
    |> Map.put_new("security_requirements", ["authentication", "authorization"])
    |> Map.put_new("transformation_complexity", "medium")
    |> Map.put_new("endpoint_count", "low")
    |> Map.put_new("reliability_requirements", "high")
    |> Map.put_new("monitoring_needs", ["basic_logging"])
    |> Map.put_new("deployment_model", "cloud_native")
    |> Map.put_new("legacy_system_support", "not_required")
  end
end