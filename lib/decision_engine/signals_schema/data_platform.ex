defmodule DecisionEngine.SignalsSchema.DataPlatform do
  @moduledoc """
  Signal schema definition for Data Platform domain.
  
  Defines the structure and validation rules for signals extracted from
  user scenarios in the Data Platform decision domain.
  """

  @behaviour DecisionEngine.SignalsSchema.Behaviour

  @schema %{
    "type" => "object",
    "required" => ["data_volume", "processing_type", "latency_requirements"],
    "properties" => %{
      "data_volume" => %{
        "type" => "string",
        "enum" => ["small", "medium", "large", "very_large"],
        "description" => "Volume of data to be processed"
      },
      "data_velocity" => %{
        "type" => "string",
        "enum" => ["low", "medium", "high", "very_high"],
        "description" => "Speed at which data arrives and needs processing"
      },
      "data_variety" => %{
        "type" => "string",
        "enum" => ["structured", "semi_structured", "unstructured", "mixed"],
        "description" => "Types and formats of data being processed"
      },
      "processing_type" => %{
        "type" => "string",
        "enum" => ["batch", "streaming", "etl", "mixed"],
        "description" => "Primary data processing pattern required"
      },
      "latency_requirements" => %{
        "type" => "string",
        "enum" => ["batch", "near_real_time", "real_time"],
        "description" => "Required response time for data processing"
      },
      "consistency_requirements" => %{
        "type" => "string",
        "enum" => ["eventual", "flexible", "strong", "strict_acid"],
        "description" => "Data consistency requirements"
      },
      "analytics_needs" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["business_intelligence", "data_warehousing", "machine_learning", "reporting", "ad_hoc_queries"]
        },
        "description" => "Types of analytics and reporting needed"
      },
      "storage_duration" => %{
        "type" => "string",
        "enum" => ["short_term", "medium_term", "long_term", "archival"],
        "description" => "How long data needs to be retained"
      },
      "compliance_requirements" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ["gdpr", "hipaa", "sox", "data_residency", "encryption_at_rest", "none"]
        },
        "description" => "Data compliance and regulatory requirements"
      },
      "budget_constraints" => %{
        "type" => "string",
        "enum" => ["very_low", "low", "medium", "high", "unlimited"],
        "description" => "Budget constraints for the data platform solution"
      }
    }
  }

  @impl DecisionEngine.SignalsSchema.Behaviour
  def schema, do: @schema

  @impl DecisionEngine.SignalsSchema.Behaviour
  def apply_defaults(signals) do
    signals
    |> Map.put_new("data_volume", "medium")
    |> Map.put_new("data_velocity", "medium")
    |> Map.put_new("data_variety", "structured")
    |> Map.put_new("processing_type", "batch")
    |> Map.put_new("latency_requirements", "batch")
    |> Map.put_new("consistency_requirements", "strong")
    |> Map.put_new("analytics_needs", ["reporting"])
    |> Map.put_new("storage_duration", "medium_term")
    |> Map.put_new("compliance_requirements", ["none"])
    |> Map.put_new("budget_constraints", "medium")
  end
end