defmodule DecisionEngine.DomainConfigBuilder do
  @moduledoc """
  Builds domain configurations from LLM responses for PDF processing workflow.

  This module parses LLM-generated content and converts it into valid domain
  configurations that can be used by the domain management system. It handles
  validation, default value application, and error recovery for unclear content.
  """

  require Logger
  alias DecisionEngine.Types

  @type llm_response :: %{
    String.t() => term()
  }

  @type domain_config :: %{
    name: String.t(),
    display_name: String.t(),
    description: String.t(),
    signals_fields: [String.t()],
    patterns: [Types.pattern()],
    schema_module: String.t(),
    metadata: %{
      source_file: String.t(),
      generated_at: DateTime.t(),
      llm_model: String.t(),
      processing_time: integer(),
      confidence: float()
    }
  }

  @doc """
  Builds a domain configuration from an LLM response.

  Parses the LLM response and converts it into a structured domain configuration
  that can be used by the domain management system. Applies validation and
  default values as needed.

  ## Parameters
  - llm_response: Map containing the LLM-generated domain configuration
  - domain_name: The target domain name for the configuration
  - options: Optional configuration (source_file, llm_model, etc.)

  ## Returns
  - {:ok, domain_config()} on success
  - {:error, [String.t()]} on validation failure with list of errors

  ## Examples
      iex> response = %{"patterns" => [...], "signals_fields" => [...]}
      iex> DomainConfigBuilder.build_from_llm_response(response, "ai_platform")
      {:ok, %{name: "ai_platform", patterns: [...], ...}}
  """
  @spec build_from_llm_response(llm_response(), String.t(), keyword()) ::
    {:ok, domain_config()} | {:error, [String.t()]}
  def build_from_llm_response(llm_response, domain_name, options \\ []) do
    Logger.info("Building domain configuration for #{domain_name} from LLM response")

    start_time = System.monotonic_time(:millisecond)

    with {:ok, parsed_config} <- parse_llm_response(llm_response, domain_name),
         {:ok, config_with_defaults} <- apply_defaults(parsed_config, domain_name),
         {:ok, validated_config} <- validate_generated_config(config_with_defaults),
         {:ok, final_config} <- add_metadata(validated_config, options, start_time) do

      Logger.info("Successfully built domain configuration for #{domain_name}")
      {:ok, final_config}
    else
      {:error, errors} when is_list(errors) ->
        Logger.warning("Failed to build domain configuration for #{domain_name}: #{inspect(errors)}")
        {:error, errors}

      {:error, error} ->
        Logger.warning("Failed to build domain configuration for #{domain_name}: #{inspect(error)}")
        {:error, [to_string(error)]}
    end
  end

  @doc """
  Validates a generated domain configuration against schema requirements.

  Performs comprehensive validation including structure validation, field
  consistency checks, and pattern validation.

  ## Parameters
  - config: The domain configuration map to validate

  ## Returns
  - {:ok, config} if validation passes
  - {:error, [String.t()]} with list of validation errors

  ## Examples
      iex> config = %{name: "test", signals_fields: ["field1"], patterns: [...]}
      iex> DomainConfigBuilder.validate_generated_config(config)
      {:ok, config}
  """
  @spec validate_generated_config(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_generated_config(config) when is_map(config) do
    Logger.debug("Validating generated domain configuration")

    errors = []

    # Validate required fields
    errors = validate_required_fields(config, errors)

    # Validate signals fields
    errors = validate_signals_fields(config, errors)

    # Validate patterns structure
    errors = validate_patterns_structure(config, errors)

    # Validate pattern consistency
    errors = validate_pattern_consistency(config, errors)

    case errors do
      [] ->
        Logger.debug("Domain configuration validation passed")
        {:ok, config}
      _ ->
        Logger.warning("Domain configuration validation failed: #{inspect(errors)}")
        {:error, errors}
    end
  end

  def validate_generated_config(_), do: {:error, ["Configuration must be a map"]}

  @doc """
  Applies default values for missing configuration elements.

  Fills in missing or incomplete configuration elements with sensible defaults
  based on the domain name and existing configuration.

  ## Parameters
  - config: The domain configuration map
  - domain_name: The target domain name

  ## Returns
  - {:ok, config_with_defaults} with defaults applied
  - {:error, reason} if defaults cannot be applied

  ## Examples
      iex> config = %{name: "test", signals_fields: ["field1"]}
      iex> DomainConfigBuilder.apply_defaults(config, "test")
      {:ok, %{name: "test", signals_fields: ["field1"], patterns: [...], ...}}
  """
  @spec apply_defaults(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def apply_defaults(config, domain_name) when is_map(config) and is_binary(domain_name) do
    Logger.debug("Applying defaults to domain configuration for #{domain_name}")

    try do
      config_with_defaults =
        config
        |> ensure_display_name(domain_name)
        |> ensure_description(domain_name)
        |> ensure_schema_module(domain_name)
        |> ensure_patterns(domain_name)
        |> ensure_signals_fields()

      Logger.debug("Successfully applied defaults to domain configuration")
      {:ok, config_with_defaults}
    rescue
      error ->
        Logger.error("Failed to apply defaults: #{inspect(error)}")
        {:error, "Failed to apply defaults: #{inspect(error)}"}
    end
  end

  def apply_defaults(_, _), do: {:error, "Invalid configuration or domain name"}

  @doc """
  Handles unclear or insufficient content scenarios.

  When the LLM response is unclear or insufficient, this function generates
  a basic domain structure and provides guidance for user refinement.

  ## Parameters
  - unclear_response: The unclear or insufficient LLM response
  - domain_name: The target domain name
  - options: Optional configuration for handling unclear content

  ## Returns
  - {:ok, basic_config} with basic structure and refinement guidance
  - {:error, reason} if basic structure cannot be generated

  ## Examples
      iex> unclear = %{"unclear" => "content"}
      iex> DomainConfigBuilder.handle_unclear_content(unclear, "test")
      {:ok, %{name: "test", refinement_needed: true, ...}}
  """
  @spec handle_unclear_content(map(), String.t(), keyword()) ::
    {:ok, domain_config()} | {:error, String.t()}
  def handle_unclear_content(unclear_response, domain_name, options \\ []) do
    Logger.info("Handling unclear content for domain #{domain_name}")

    # Extract any usable information from the unclear response
    extracted_signals = extract_signals_from_unclear(unclear_response)
    extracted_patterns = extract_patterns_from_unclear(unclear_response, domain_name)

    basic_config = %{
      name: domain_name,
      display_name: format_display_name(domain_name),
      description: generate_basic_description(domain_name, unclear_response),
      signals_fields: extracted_signals,
      patterns: extracted_patterns,
      schema_module: generate_schema_module_name(domain_name),
      refinement_needed: true,
      refinement_guidance: generate_refinement_guidance(unclear_response, domain_name),
      metadata: %{
        source_file: Keyword.get(options, :source_file, "unknown"),
        generated_at: DateTime.utc_now(),
        llm_model: Keyword.get(options, :llm_model, "unknown"),
        processing_time: 0,
        confidence: 0.3,  # Low confidence for unclear content
        unclear_content: true
      }
    }

    Logger.info("Generated basic domain configuration for unclear content")
    {:ok, basic_config}
  end

  ## Private Functions

  defp parse_llm_response(llm_response, domain_name) do
    Logger.debug("Parsing LLM response for domain #{domain_name}")

    # Handle different response formats
    case llm_response do
      %{"domain_config" => config} when is_map(config) ->
        # Normalize patterns if they exist
        normalized_config = case config["patterns"] do
          patterns when is_list(patterns) ->
            normalized_patterns =
              patterns
              |> Enum.with_index()
              |> Enum.map(fn {pattern, index} -> normalize_pattern(pattern, domain_name, index) end)

            Map.put(config, "patterns", normalized_patterns)

          _ -> config
        end

        {:ok, Map.put(normalized_config, "name", domain_name)}

      %{"patterns" => patterns, "signals_fields" => _} = config ->
        normalized_patterns =
          patterns
          |> Enum.with_index()
          |> Enum.map(fn {pattern, index} -> normalize_pattern(pattern, domain_name, index) end)

        normalized_config =
          config
          |> Map.put("name", domain_name)
          |> Map.put("patterns", normalized_patterns)

        {:ok, normalized_config}

      config when is_map(config) ->
        # Try to extract configuration from top-level response
        extracted = extract_config_from_response(config, domain_name)
        {:ok, extracted}

      _ ->
        {:error, ["Invalid LLM response format"]}
    end
  end

  defp extract_config_from_response(response, domain_name) do
    %{
      "name" => domain_name,
      "signals_fields" => extract_signals_fields(response),
      "patterns" => extract_patterns(response, domain_name),
      "description" => extract_description(response, domain_name),
      "display_name" => extract_display_name(response, domain_name)
    }
  end

  defp extract_signals_fields(response) do
    cond do
      Map.has_key?(response, "signals_fields") -> response["signals_fields"]
      Map.has_key?(response, "fields") -> response["fields"]
      Map.has_key?(response, "signal_fields") -> response["signal_fields"]
      true -> []
    end
  end

  defp extract_patterns(response, domain_name) do
    patterns = cond do
      Map.has_key?(response, "patterns") -> response["patterns"]
      Map.has_key?(response, "rules") -> response["rules"]
      Map.has_key?(response, "decision_patterns") -> response["decision_patterns"]
      true -> []
    end

    # Ensure patterns have required structure
    patterns
    |> Enum.with_index()
    |> Enum.map(fn {pattern, index} -> normalize_pattern(pattern, domain_name, index) end)
  end

  defp extract_description(response, domain_name) do
    cond do
      Map.has_key?(response, "description") -> response["description"]
      Map.has_key?(response, "summary") -> response["summary"]
      Map.has_key?(response, "overview") -> response["overview"]
      true -> "Generated domain configuration for #{domain_name}"
    end
  end

  defp extract_display_name(response, domain_name) do
    cond do
      Map.has_key?(response, "display_name") -> response["display_name"]
      Map.has_key?(response, "name") -> response["name"]
      Map.has_key?(response, "title") -> response["title"]
      true -> format_display_name(domain_name)
    end
  end

  defp normalize_pattern(pattern, domain_name, index) when is_map(pattern) do
    raw_score = pattern["score"] || pattern["confidence"] || 0.7

    %{
      "id" => pattern["id"] || "#{domain_name}_pattern_#{index + 1}",
      "outcome" => pattern["outcome"] || pattern["recommendation"] || "recommend_#{domain_name}_solution",
      "score" => normalize_score(raw_score),
      "summary" => pattern["summary"] || pattern["description"] || "Pattern #{index + 1} for #{domain_name}",
      "use_when" => normalize_conditions(pattern["use_when"] || pattern["conditions"] || []),
      "avoid_when" => normalize_conditions(pattern["avoid_when"] || pattern["avoid_conditions"] || []),
      "typical_use_cases" => pattern["typical_use_cases"] || pattern["use_cases"] || []
    }
  end

  defp normalize_pattern(_, domain_name, index) do
    # Fallback for non-map patterns
    %{
      "id" => "#{domain_name}_pattern_#{index + 1}",
      "outcome" => "recommend_#{domain_name}_solution",
      "score" => 0.7,
      "summary" => "Generated pattern #{index + 1} for #{domain_name}",
      "use_when" => [],
      "avoid_when" => [],
      "typical_use_cases" => []
    }
  end

  defp normalize_score(score) when is_number(score) do
    cond do
      score < 0 -> 0.0
      score > 1 -> 1.0
      true -> score
    end
  end

  defp normalize_score(_), do: 0.7

  defp normalize_conditions(conditions) when is_list(conditions) do
    Enum.map(conditions, &normalize_condition/1)
  end

  defp normalize_conditions(_), do: []

  defp normalize_condition(condition) when is_map(condition) do
    %{
      "field" => condition["field"] || "example_field",
      "op" => condition["op"] || condition["operator"] || "in",
      "value" => condition["value"] || condition["values"] || ["example_value"]
    }
  end

  defp normalize_condition(_), do: %{"field" => "example_field", "op" => "in", "value" => ["example_value"]}

  defp validate_required_fields(config, errors) do
    required_fields = ["name", "signals_fields", "patterns"]

    Enum.reduce(required_fields, errors, fn field, acc ->
      if Map.has_key?(config, field) do
        acc
      else
        ["Missing required field: #{field}" | acc]
      end
    end)
  end

  defp validate_signals_fields(config, errors) do
    case config["signals_fields"] do
      fields when is_list(fields) and length(fields) > 0 ->
        # Validate that all fields are strings
        if Enum.all?(fields, &is_binary/1) do
          errors
        else
          ["All signal fields must be strings" | errors]
        end

      fields when is_list(fields) ->
        ["At least one signal field is required" | errors]

      _ ->
        ["signals_fields must be a list" | errors]
    end
  end

  defp validate_patterns_structure(config, errors) do
    case config["patterns"] do
      patterns when is_list(patterns) ->
        patterns
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {pattern, index}, acc ->
          validate_single_pattern(pattern, index, acc)
        end)

      _ ->
        ["patterns must be a list" | errors]
    end
  end

  defp validate_single_pattern(pattern, index, errors) when is_map(pattern) do
    required_pattern_fields = ["id", "outcome", "score", "summary", "use_when", "avoid_when"]

    Enum.reduce(required_pattern_fields, errors, fn field, acc ->
      if Map.has_key?(pattern, field) do
        acc
      else
        ["Pattern #{index + 1}: Missing required field '#{field}'" | acc]
      end
    end)
  end

  defp validate_single_pattern(_, index, errors) do
    ["Pattern #{index + 1}: Must be a map" | errors]
  end

  defp validate_pattern_consistency(config, errors) do
    patterns = config["patterns"] || []
    signals_fields = MapSet.new(config["signals_fields"] || [])

    # Check that pattern conditions reference valid signal fields
    patterns
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {pattern, index}, acc ->
      validate_pattern_field_references(pattern, index, signals_fields, acc)
    end)
  end

  defp validate_pattern_field_references(pattern, index, signals_fields, errors) when is_map(pattern) do
    use_when = pattern["use_when"] || []
    avoid_when = pattern["avoid_when"] || []
    conditions = use_when ++ avoid_when

    Enum.reduce(conditions, errors, fn condition, acc ->
      case condition do
        %{"field" => field} when is_binary(field) ->
          if MapSet.member?(signals_fields, field) or field == "example_field" do
            acc
          else
            ["Pattern #{index + 1}: References undefined signal field '#{field}'" | acc]
          end

        _ ->
          ["Pattern #{index + 1}: Invalid condition structure" | acc]
      end
    end)
  end

  defp validate_pattern_field_references(_, index, _, errors) do
    ["Pattern #{index + 1}: Pattern must be a map" | errors]
  end

  defp ensure_display_name(config, domain_name) do
    if Map.has_key?(config, "display_name") and config["display_name"] != "" do
      config
    else
      Map.put(config, "display_name", format_display_name(domain_name))
    end
  end

  defp ensure_description(config, domain_name) do
    if Map.has_key?(config, "description") and config["description"] != "" do
      config
    else
      description = "Domain configuration for #{format_display_name(domain_name)} generated from PDF analysis"
      Map.put(config, "description", description)
    end
  end

  defp ensure_schema_module(config, domain_name) do
    if Map.has_key?(config, "schema_module") and config["schema_module"] != "" do
      config
    else
      Map.put(config, "schema_module", generate_schema_module_name(domain_name))
    end
  end

  defp ensure_patterns(config, domain_name) do
    case config["patterns"] do
      patterns when is_list(patterns) and length(patterns) > 0 ->
        config

      _ ->
        default_pattern = create_default_pattern(domain_name, config["signals_fields"] || [])
        Map.put(config, "patterns", [default_pattern])
    end
  end

  defp ensure_signals_fields(config) do
    case config["signals_fields"] do
      fields when is_list(fields) and length(fields) > 0 ->
        config

      _ ->
        Map.put(config, "signals_fields", ["primary_requirement", "technical_constraint"])
    end
  end

  defp create_default_pattern(domain_name, signals_fields) do
    first_field = List.first(signals_fields) || "primary_requirement"

    %{
      "id" => "#{domain_name}_default",
      "outcome" => "recommend_#{domain_name}_solution",
      "score" => 0.8,
      "summary" => "Default recommendation pattern for #{format_display_name(domain_name)}",
      "use_when" => [
        %{
          "field" => first_field,
          "op" => "in",
          "value" => ["standard", "typical", "common"]
        }
      ],
      "avoid_when" => [
        %{
          "field" => first_field,
          "op" => "in",
          "value" => ["incompatible", "unsupported"]
        }
      ],
      "typical_use_cases" => [
        "Standard #{domain_name} implementation",
        "Typical #{domain_name} use case"
      ]
    }
  end

  defp add_metadata(config, options, start_time) do
    end_time = System.monotonic_time(:millisecond)
    processing_time = end_time - start_time

    metadata = %{
      source_file: Keyword.get(options, :source_file, "unknown"),
      generated_at: DateTime.utc_now(),
      llm_model: Keyword.get(options, :llm_model, "unknown"),
      processing_time: processing_time,
      confidence: calculate_confidence(config)
    }

    # Convert to atom keys for struct-like access
    final_config =
      config
      |> Map.put("metadata", metadata)
      |> convert_to_atom_keys()

    {:ok, final_config}
  end

  defp convert_to_atom_keys(config) when is_map(config) do
    config
    |> Enum.map(fn
      {"name", value} -> {:name, value}
      {"display_name", value} -> {:display_name, value}
      {"description", value} -> {:description, value}
      {"signals_fields", value} -> {:signals_fields, value}
      {"patterns", value} -> {:patterns, value}
      {"schema_module", value} -> {:schema_module, value}
      {"metadata", value} -> {:metadata, value}
      {"refinement_needed", value} -> {:refinement_needed, value}
      {"refinement_guidance", value} -> {:refinement_guidance, value}
      {key, value} -> {String.to_atom(key), value}
    end)
    |> Map.new()
  end

  defp calculate_confidence(config) do
    # Calculate confidence based on completeness and quality of configuration
    base_confidence = 0.7

    # Boost confidence for complete configurations
    confidence = if length(config["patterns"] || []) > 1, do: base_confidence + 0.1, else: base_confidence
    confidence = if length(config["signals_fields"] || []) > 2, do: confidence + 0.1, else: confidence
    confidence = if config["description"] && String.length(config["description"]) > 50, do: confidence + 0.1, else: confidence

    min(confidence, 1.0)
  end

  defp format_display_name(domain_name) do
    domain_name
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp generate_schema_module_name(domain_name) do
    module_name =
      domain_name
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("")

    "DecisionEngine.SignalsSchema.#{module_name}"
  end

  defp extract_signals_from_unclear(unclear_response) do
    # Try to extract any field-like information from unclear content
    potential_fields = []

    # Look for common field patterns in the response
    potential_fields = extract_field_patterns(unclear_response, potential_fields)

    # Provide default fields if nothing found
    if Enum.empty?(potential_fields) do
      ["primary_requirement", "technical_constraint", "business_context"]
    else
      potential_fields
    end
  end

  defp extract_field_patterns(response, fields) when is_map(response) do
    response
    |> Map.keys()
    |> Enum.reduce(fields, fn key, acc ->
      if String.contains?(key, ["field", "signal", "input", "requirement"]) do
        [key | acc]
      else
        acc
      end
    end)
  end

  defp extract_field_patterns(_, fields), do: fields

  defp extract_patterns_from_unclear(unclear_response, domain_name) do
    # Generate a basic pattern from unclear content
    [create_default_pattern(domain_name, extract_signals_from_unclear(unclear_response))]
  end

  defp generate_basic_description(domain_name, unclear_response) do
    base_description = "Domain configuration for #{format_display_name(domain_name)} generated from PDF content."

    # Try to extract any descriptive content
    additional_info = case unclear_response do
      %{"description" => desc} when is_binary(desc) -> " #{desc}"
      %{"summary" => summary} when is_binary(summary) -> " #{summary}"
      %{"content" => content} when is_binary(content) -> " Based on: #{String.slice(content, 0, 100)}..."
      _ -> " Content analysis was unclear and may require manual refinement."
    end

    base_description <> additional_info
  end

  defp generate_refinement_guidance(unclear_response, domain_name) do
    %{
      message: "The PDF content was unclear or insufficient for automatic domain generation.",
      suggestions: [
        "Review and refine the generated signal fields to match your specific requirements",
        "Update the decision patterns to reflect your business rules and decision criteria",
        "Enhance the domain description with more specific details about #{format_display_name(domain_name)}",
        "Consider uploading a more detailed PDF or manually configuring the domain"
      ],
      unclear_elements: identify_unclear_elements(unclear_response),
      next_steps: [
        "Edit the domain configuration in the management interface",
        "Test the domain with sample scenarios",
        "Iterate on patterns based on real-world usage"
      ]
    }
  end

  defp identify_unclear_elements(unclear_response) do
    elements = []

    elements = if not Map.has_key?(unclear_response, "patterns"), do: ["decision_patterns" | elements], else: elements
    elements = if not Map.has_key?(unclear_response, "signals_fields"), do: ["signal_fields" | elements], else: elements
    elements = if not Map.has_key?(unclear_response, "description"), do: ["description" | elements], else: elements

    elements
  end
end
