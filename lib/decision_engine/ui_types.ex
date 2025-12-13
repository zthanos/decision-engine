defmodule DecisionEngine.UITypes do
  @moduledoc """
  Type definitions for UI enhancements including history entries and domain descriptions.
  """

  @typedoc """
  History entry structure for completed analyses.
  """
  @type history_entry :: %{
    id: String.t(),
    timestamp: DateTime.t(),
    scenario: String.t(),
    domain: atom(),
    signals: map(),
    decision: map(),
    justification: map(),
    metadata: history_metadata()
  }

  @typedoc """
  Metadata for history entries containing processing information.
  """
  @type history_metadata :: %{
    provider: String.t(),
    model: String.t(),
    processing_time: integer(),
    streaming_enabled: boolean()
  }

  @typedoc """
  Domain description structure for AI-generated descriptions.
  """
  @type domain_description :: %{
    domain: atom(),
    description: String.t(),
    generated_at: DateTime.t(),
    rule_config_hash: String.t(),
    status: :generated | :manual | :error
  }

  @typedoc """
  History storage format for file persistence.
  """
  @type history_storage :: %{
    version: String.t(),
    created_at: String.t(),
    entries: [map()]
  }

  @typedoc """
  Domain descriptions storage format for file persistence.
  """
  @type descriptions_storage :: %{
    version: String.t(),
    updated_at: String.t(),
    descriptions: map()
  }

  @doc """
  Creates a new history entry from analysis results.

  ## Parameters
  - analysis: Map containing analysis results

  ## Returns
  - history_entry() struct
  """
  @spec create_history_entry(map()) :: history_entry()
  def create_history_entry(analysis) do
    %{
      id: generate_uuid(),
      timestamp: DateTime.utc_now(),
      scenario: get_field(analysis, :scenario, ""),
      domain: get_field(analysis, :domain, :unknown),
      signals: get_field(analysis, :signals, %{}),
      decision: get_field(analysis, :decision, %{}),
      justification: get_field(analysis, :justification, %{}),
      metadata: create_metadata(analysis)
    }
  end

  @doc """
  Creates a new domain description entry.

  ## Parameters
  - domain: Atom representing the domain
  - description: String description text
  - rule_config: Map of rule configuration (for hash generation)
  - status: Status of the description (:generated, :manual, :error)

  ## Returns
  - domain_description() struct
  """
  @spec create_domain_description(atom(), String.t(), map(), atom()) :: domain_description()
  def create_domain_description(domain, description, rule_config, status \\ :generated) do
    %{
      domain: domain,
      description: description,
      generated_at: DateTime.utc_now(),
      rule_config_hash: generate_config_hash(rule_config),
      status: status
    }
  end

  @doc """
  Validates a history entry structure.

  ## Parameters
  - entry: Map to validate as history entry

  ## Returns
  - :ok if valid
  - {:error, reason} if invalid
  """
  @spec validate_history_entry(map()) :: :ok | {:error, String.t()}
  def validate_history_entry(entry) do
    required_fields = [:id, :timestamp, :scenario, :domain, :signals, :decision, :justification, :metadata]

    case check_required_fields(entry, required_fields) do
      :ok -> validate_entry_types(entry)
      error -> error
    end
  end

  @doc """
  Validates a domain description structure.

  ## Parameters
  - description: Map to validate as domain description

  ## Returns
  - :ok if valid
  - {:error, reason} if invalid
  """
  @spec validate_domain_description(map()) :: :ok | {:error, String.t()}
  def validate_domain_description(description) do
    required_fields = [:domain, :description, :generated_at, :rule_config_hash, :status]

    case check_required_fields(description, required_fields) do
      :ok -> validate_description_types(description)
      error -> error
    end
  end

  @doc """
  Converts a history entry to a map suitable for JSON serialization.

  ## Parameters
  - entry: history_entry() to serialize

  ## Returns
  - Map with string keys suitable for JSON encoding
  """
  @spec serialize_history_entry(history_entry()) :: map()
  def serialize_history_entry(entry) do
    %{
      "id" => entry.id,
      "timestamp" => DateTime.to_iso8601(entry.timestamp),
      "scenario" => entry.scenario,
      "domain" => Atom.to_string(entry.domain),
      "signals" => entry.signals,
      "decision" => entry.decision,
      "justification" => entry.justification,
      "metadata" => entry.metadata
    }
  end

  @doc """
  Parses a serialized history entry back to the internal format.

  ## Parameters
  - serialized: Map with string keys from JSON

  ## Returns
  - history_entry() struct
  """
  @spec parse_history_entry(map()) :: history_entry()
  def parse_history_entry(serialized) do
    %{
      id: serialized["id"],
      timestamp: parse_timestamp(serialized["timestamp"]),
      scenario: serialized["scenario"],
      domain: String.to_atom(serialized["domain"]),
      signals: serialized["signals"],
      decision: serialized["decision"],
      justification: serialized["justification"],
      metadata: serialized["metadata"] || %{}
    }
  end

  @doc """
  Converts a domain description to a map suitable for JSON serialization.

  ## Parameters
  - description: domain_description() to serialize

  ## Returns
  - Map with string keys suitable for JSON encoding
  """
  @spec serialize_domain_description(domain_description()) :: map()
  def serialize_domain_description(description) do
    %{
      "domain" => Atom.to_string(description.domain),
      "description" => description.description,
      "generated_at" => DateTime.to_iso8601(description.generated_at),
      "rule_config_hash" => description.rule_config_hash,
      "status" => Atom.to_string(description.status)
    }
  end

  @doc """
  Parses a serialized domain description back to the internal format.

  ## Parameters
  - serialized: Map with string keys from JSON

  ## Returns
  - domain_description() struct
  """
  @spec parse_domain_description(map()) :: domain_description()
  def parse_domain_description(serialized) do
    %{
      domain: String.to_atom(serialized["domain"]),
      description: serialized["description"],
      generated_at: parse_timestamp(serialized["generated_at"]),
      rule_config_hash: serialized["rule_config_hash"],
      status: String.to_atom(serialized["status"])
    }
  end

  # Private Functions

  defp get_field(map, key, default) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp create_metadata(analysis) do
    metadata = get_field(analysis, :metadata, %{})

    %{
      provider: get_field(metadata, :provider, "unknown"),
      model: get_field(metadata, :model, "unknown"),
      processing_time: get_field(metadata, :processing_time, 0),
      streaming_enabled: get_field(metadata, :streaming_enabled, false)
    }
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
  end

  defp generate_config_hash(rule_config) do
    rule_config
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp check_required_fields(map, fields) do
    missing_fields = Enum.filter(fields, &(not Map.has_key?(map, &1)))

    case missing_fields do
      [] -> :ok
      missing -> {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_entry_types(entry) do
    cond do
      not is_binary(entry.id) ->
        {:error, "ID must be a string"}

      not match?(%DateTime{}, entry.timestamp) ->
        {:error, "Timestamp must be a DateTime"}

      not is_binary(entry.scenario) ->
        {:error, "Scenario must be a string"}

      not is_atom(entry.domain) ->
        {:error, "Domain must be an atom"}

      not is_map(entry.signals) ->
        {:error, "Signals must be a map"}

      not is_map(entry.decision) ->
        {:error, "Decision must be a map"}

      not is_map(entry.justification) ->
        {:error, "Justification must be a map"}

      not is_map(entry.metadata) ->
        {:error, "Metadata must be a map"}

      true ->
        :ok
    end
  end

  defp validate_description_types(description) do
    cond do
      not is_atom(description.domain) ->
        {:error, "Domain must be an atom"}

      not is_binary(description.description) ->
        {:error, "Description must be a string"}

      not match?(%DateTime{}, description.generated_at) ->
        {:error, "Generated_at must be a DateTime"}

      not is_binary(description.rule_config_hash) ->
        {:error, "Rule_config_hash must be a string"}

      description.status not in [:generated, :manual, :error] ->
        {:error, "Status must be :generated, :manual, or :error"}

      true ->
        :ok
    end
  end

  defp parse_timestamp(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end
end
