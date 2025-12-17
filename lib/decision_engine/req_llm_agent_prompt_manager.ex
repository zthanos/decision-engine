defmodule DecisionEngine.ReqLLMAgentPromptManager do
  @moduledoc """
  Manages structured prompt templates for agentic workflows.

  This module provides structured prompt support for agents, including template
  management, prompt validation, response parsing, and agent-specific optimizations.
  Supports the agentic reflection pattern and other complex AI workflows.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger
  alias DecisionEngine.ReqLLMCorrelation

  @type prompt_template :: %{
    id: String.t(),
    name: String.t(),
    description: String.t(),
    template: String.t(),
    variables: [String.t()],
    response_format: map(),
    validation_rules: [map()],
    optimization_hints: map(),
    metadata: map()
  }

  @type structured_prompt :: %{
    template_id: String.t(),
    rendered_prompt: String.t(),
    variables: map(),
    response_format: map(),
    validation_context: map()
  }

  @doc """
  Creates a new structured prompt template for agents.

  ## Parameters
  - template_data: Map containing template definition
  - agent_type: Type of agent this template is for (:reflection, :refinement, :evaluation, etc.)

  ## Returns
  - {:ok, template} on successful creation
  - {:error, reason} if creation fails
  """
  @spec create_template(map(), atom()) :: {:ok, prompt_template()} | {:error, term()}
  def create_template(template_data, agent_type) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with :ok <- validate_template_data(template_data),
         {:ok, template} <- build_template(template_data, agent_type),
         :ok <- store_template(template) do

      ReqLLMLogger.log_agent_event(:template_created, %{
        template_id: template.id,
        agent_type: agent_type,
        variables_count: length(template.variables)
      }, %{correlation_id: correlation_id})

      {:ok, template}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:template_creation_failed, %{
          agent_type: agent_type,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Renders a structured prompt from a template with provided variables.

  ## Parameters
  - template_id: ID of the template to use
  - variables: Map of variables to substitute in the template
  - options: Additional rendering options

  ## Returns
  - {:ok, structured_prompt} on successful rendering
  - {:error, reason} if rendering fails
  """
  @spec render_prompt(String.t(), map(), map()) :: {:ok, structured_prompt()} | {:error, term()}
  def render_prompt(template_id, variables \\ %{}, options \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, template} <- get_template(template_id),
         :ok <- validate_variables(template, variables),
         {:ok, rendered} <- perform_rendering(template, variables, options) do

      ReqLLMLogger.log_agent_event(:prompt_rendered, %{
        template_id: template_id,
        variables_provided: map_size(variables),
        prompt_length: String.length(rendered.rendered_prompt)
      }, %{correlation_id: correlation_id})

      {:ok, rendered}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:prompt_rendering_failed, %{
          template_id: template_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Validates a structured prompt before sending to LLM.

  ## Parameters
  - structured_prompt: The structured prompt to validate
  - validation_options: Additional validation options

  ## Returns
  - :ok if validation passes
  - {:error, reason} if validation fails
  """
  @spec validate_prompt(structured_prompt(), map()) :: :ok | {:error, term()}
  def validate_prompt(structured_prompt, validation_options \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, template} <- get_template(structured_prompt.template_id),
         :ok <- validate_prompt_structure(structured_prompt),
         :ok <- validate_against_rules(structured_prompt, template.validation_rules),
         :ok <- validate_response_format(structured_prompt.response_format) do

      ReqLLMLogger.log_agent_event(:prompt_validated, %{
        template_id: structured_prompt.template_id,
        validation_rules_count: length(template.validation_rules)
      }, %{correlation_id: correlation_id})

      :ok
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:prompt_validation_failed, %{
          template_id: structured_prompt.template_id,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Parses LLM response according to structured prompt format.

  ## Parameters
  - response: Raw LLM response string
  - structured_prompt: The structured prompt that generated this response
  - parsing_options: Additional parsing options

  ## Returns
  - {:ok, parsed_response} on successful parsing
  - {:error, reason} if parsing fails
  """
  @spec parse_response(String.t(), structured_prompt(), map()) :: {:ok, map()} | {:error, term()}
  def parse_response(response, structured_prompt, parsing_options \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, template} <- get_template(structured_prompt.template_id),
         {:ok, parsed} <- perform_response_parsing(response, structured_prompt.response_format, parsing_options),
         :ok <- validate_parsed_response(parsed, template.validation_rules) do

      ReqLLMLogger.log_agent_event(:response_parsed, %{
        template_id: structured_prompt.template_id,
        response_length: String.length(response),
        parsed_fields: map_size(parsed)
      }, %{correlation_id: correlation_id})

      {:ok, parsed}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:response_parsing_failed, %{
          template_id: structured_prompt.template_id,
          error: reason,
          response_preview: String.slice(response, 0, 100)
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Optimizes a prompt template for better agent performance.

  ## Parameters
  - template_id: ID of the template to optimize
  - optimization_data: Performance data and feedback for optimization
  - agent_type: Type of agent using this template

  ## Returns
  - {:ok, optimized_template} on successful optimization
  - {:error, reason} if optimization fails
  """
  @spec optimize_template(String.t(), map(), atom()) :: {:ok, prompt_template()} | {:error, term()}
  def optimize_template(template_id, optimization_data, agent_type) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    with {:ok, template} <- get_template(template_id),
         {:ok, optimizations} <- analyze_optimization_data(optimization_data, agent_type),
         {:ok, optimized_template} <- apply_optimizations(template, optimizations),
         :ok <- store_template(optimized_template) do

      ReqLLMLogger.log_agent_event(:template_optimized, %{
        template_id: template_id,
        agent_type: agent_type,
        optimizations_applied: map_size(optimizations)
      }, %{correlation_id: correlation_id})

      {:ok, optimized_template}
    else
      {:error, reason} ->
        ReqLLMLogger.log_agent_event(:template_optimization_failed, %{
          template_id: template_id,
          agent_type: agent_type,
          error: reason
        }, %{correlation_id: correlation_id})
        {:error, reason}
    end
  end

  @doc """
  Lists available prompt templates for a specific agent type.

  ## Parameters
  - agent_type: Type of agent to get templates for (optional, nil for all)
  - filters: Additional filters to apply

  ## Returns
  - {:ok, templates} list of matching templates
  - {:error, reason} if listing fails
  """
  @spec list_templates(atom() | nil, map()) :: {:ok, [prompt_template()]} | {:error, term()}
  def list_templates(agent_type \\ nil, filters \\ %{}) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()

    try do
      templates = get_all_templates()

      filtered_templates = templates
      |> filter_by_agent_type(agent_type)
      |> apply_filters(filters)

      ReqLLMLogger.log_agent_event(:templates_listed, %{
        agent_type: agent_type,
        total_templates: length(templates),
        filtered_templates: length(filtered_templates)
      }, %{correlation_id: correlation_id})

      {:ok, filtered_templates}
    rescue
      error ->
        ReqLLMLogger.log_agent_event(:template_listing_failed, %{
          agent_type: agent_type,
          error: inspect(error)
        }, %{correlation_id: correlation_id})
        {:error, error}
    end
  end

  # Private Functions

  defp validate_template_data(template_data) do
    required_fields = [:name, :template, :variables, :response_format]

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(template_data, field) or is_nil(Map.get(template_data, field))
    end)

    if length(missing_fields) > 0 do
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    else
      validate_template_structure(template_data)
    end
  end

  defp validate_template_structure(template_data) do
    with :ok <- validate_template_string(template_data.template),
         :ok <- validate_variables_list(template_data.variables),
         :ok <- validate_response_format(template_data.response_format) do
      :ok
    end
  end

  defp validate_template_string(template) when is_binary(template) do
    if String.length(template) > 0 do
      :ok
    else
      {:error, "Template cannot be empty"}
    end
  end
  defp validate_template_string(_), do: {:error, "Template must be a string"}

  defp validate_variables_list(variables) when is_list(variables) do
    if Enum.all?(variables, &is_binary/1) do
      :ok
    else
      {:error, "All variables must be strings"}
    end
  end
  defp validate_variables_list(_), do: {:error, "Variables must be a list"}

  defp validate_response_format(format) when is_map(format) do
    if map_size(format) > 0 do
      :ok
    else
      {:error, "Response format cannot be empty"}
    end
  end
  defp validate_response_format(_), do: {:error, "Response format must be a map"}

  defp build_template(template_data, agent_type) do
    template = %{
      id: generate_template_id(),
      name: template_data.name,
      description: Map.get(template_data, :description, ""),
      template: template_data.template,
      variables: template_data.variables,
      response_format: template_data.response_format,
      validation_rules: Map.get(template_data, :validation_rules, []),
      optimization_hints: build_optimization_hints(agent_type),
      metadata: %{
        agent_type: agent_type,
        created_at: DateTime.utc_now(),
        version: "1.0.0"
      }
    }

    {:ok, template}
  end

  defp build_optimization_hints(agent_type) do
    case agent_type do
      :reflection ->
        %{
          max_prompt_length: 4000,
          preferred_response_format: :structured_json,
          optimization_focus: :accuracy,
          retry_strategy: :exponential_backoff
        }

      :refinement ->
        %{
          max_prompt_length: 3000,
          preferred_response_format: :markdown,
          optimization_focus: :consistency,
          retry_strategy: :linear_backoff
        }

      :evaluation ->
        %{
          max_prompt_length: 2000,
          preferred_response_format: :structured_json,
          optimization_focus: :speed,
          retry_strategy: :immediate_retry
        }

      _ ->
        %{
          max_prompt_length: 3000,
          preferred_response_format: :text,
          optimization_focus: :balanced,
          retry_strategy: :exponential_backoff
        }
    end
  end

  defp store_template(template) do
    # Store template in ETS table for fast access
    table_name = :req_llm_agent_templates

    # Create table if it doesn't exist
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    :ets.insert(table_name, {template.id, template})
    :ok
  end

  defp get_template(template_id) do
    table_name = :req_llm_agent_templates

    case :ets.lookup(table_name, template_id) do
      [{^template_id, template}] ->
        {:ok, template}
      [] ->
        {:error, "Template not found: #{template_id}"}
    end
  end

  defp get_all_templates do
    table_name = :req_llm_agent_templates

    case :ets.whereis(table_name) do
      :undefined ->
        []
      _ ->
        :ets.tab2list(table_name)
        |> Enum.map(fn {_id, template} -> template end)
    end
  end

  defp validate_variables(template, variables) do
    required_vars = MapSet.new(template.variables)
    provided_vars = MapSet.new(Map.keys(variables))

    missing_vars = MapSet.difference(required_vars, provided_vars)

    if MapSet.size(missing_vars) > 0 do
      {:error, "Missing required variables: #{Enum.join(missing_vars, ", ")}"}
    else
      :ok
    end
  end

  defp perform_rendering(template, variables, options) do
    try do
      # Simple variable substitution for now
      rendered_prompt = Enum.reduce(variables, template.template, fn {key, value}, acc ->
        String.replace(acc, "{{#{key}}}", to_string(value))
      end)

      # Check for unresolved variables
      case Regex.scan(~r/\{\{([^}]+)\}\}/, rendered_prompt) do
        [] ->
          structured_prompt = %{
            template_id: template.id,
            rendered_prompt: rendered_prompt,
            variables: variables,
            response_format: template.response_format,
            validation_context: %{
              template_version: template.metadata.version,
              rendering_options: options
            }
          }
          {:ok, structured_prompt}

        unresolved ->
          unresolved_vars = Enum.map(unresolved, fn [_, var] -> var end)
          {:error, "Unresolved template variables: #{Enum.join(unresolved_vars, ", ")}"}
      end
    rescue
      error ->
        {:error, "Template rendering failed: #{inspect(error)}"}
    end
  end

  defp validate_prompt_structure(structured_prompt) do
    required_fields = [:template_id, :rendered_prompt, :variables, :response_format]

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(structured_prompt, field)
    end)

    if length(missing_fields) > 0 do
      {:error, "Invalid prompt structure, missing: #{Enum.join(missing_fields, ", ")}"}
    else
      :ok
    end
  end

  defp validate_against_rules(structured_prompt, validation_rules) do
    Enum.reduce_while(validation_rules, :ok, fn rule, _acc ->
      case apply_validation_rule(structured_prompt, rule) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_validation_rule(structured_prompt, rule) do
    case rule do
      %{type: :max_length, value: max_len} ->
        if String.length(structured_prompt.rendered_prompt) <= max_len do
          :ok
        else
          {:error, "Prompt exceeds maximum length of #{max_len}"}
        end

      %{type: :required_content, value: required_text} ->
        if String.contains?(structured_prompt.rendered_prompt, required_text) do
          :ok
        else
          {:error, "Prompt missing required content: #{required_text}"}
        end

      %{type: :forbidden_content, value: forbidden_text} ->
        if not String.contains?(structured_prompt.rendered_prompt, forbidden_text) do
          :ok
        else
          {:error, "Prompt contains forbidden content: #{forbidden_text}"}
        end

      _ ->
        Logger.warning("Unknown validation rule type: #{inspect(rule)}")
        :ok
    end
  end

  defp perform_response_parsing(response, response_format, _options) do
    case response_format do
      %{type: :json} ->
        parse_json_response(response, response_format)

      %{type: :structured_text} ->
        parse_structured_text_response(response, response_format)

      %{type: :markdown} ->
        parse_markdown_response(response, response_format)

      _ ->
        # Default to simple text parsing
        {:ok, %{content: response, format: :text}}
    end
  end

  defp parse_json_response(response, format) do
    case Jason.decode(response) do
      {:ok, parsed} ->
        validate_json_structure(parsed, format)

      {:error, reason} ->
        # Try to extract JSON from markdown code blocks
        case extract_json_from_markdown(response) do
          {:ok, json_text} ->
            case Jason.decode(json_text) do
              {:ok, parsed} -> validate_json_structure(parsed, format)
              {:error, _} -> {:error, "Invalid JSON in response: #{inspect(reason)}"}
            end

          {:error, _} ->
            {:error, "Invalid JSON in response: #{inspect(reason)}"}
        end
    end
  end

  defp extract_json_from_markdown(text) do
    case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, text, capture: :all_but_first) do
      [json_text] -> {:ok, json_text}
      _ -> {:error, "No JSON found in markdown"}
    end
  end

  defp validate_json_structure(parsed, format) do
    required_fields = Map.get(format, :required_fields, [])

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(parsed, field)
    end)

    if length(missing_fields) > 0 do
      {:error, "Missing required fields in JSON response: #{Enum.join(missing_fields, ", ")}"}
    else
      {:ok, parsed}
    end
  end

  defp parse_structured_text_response(response, format) do
    patterns = Map.get(format, :patterns, %{})

    parsed = Enum.reduce(patterns, %{}, fn {field, pattern}, acc ->
      case Regex.run(pattern, response, capture: :all_but_first) do
        [value] -> Map.put(acc, field, String.trim(value))
        _ -> acc
      end
    end)

    {:ok, parsed}
  end

  defp parse_markdown_response(response, _format) do
    # Simple markdown parsing - extract sections
    sections = Regex.scan(~r/^## (.+)$\n(.*?)(?=^## |\z)/m, response, capture: :all_but_first)

    parsed = Enum.reduce(sections, %{}, fn [title, content], acc ->
      key = title |> String.downcase() |> String.replace(" ", "_")
      Map.put(acc, key, String.trim(content))
    end)

    {:ok, Map.put(parsed, :raw_content, response)}
  end

  defp validate_parsed_response(parsed, validation_rules) do
    Enum.reduce_while(validation_rules, :ok, fn rule, _acc ->
      case apply_response_validation_rule(parsed, rule) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_response_validation_rule(parsed, rule) do
    case rule do
      %{type: :required_field, field: field} ->
        if Map.has_key?(parsed, field) and not is_nil(Map.get(parsed, field)) do
          :ok
        else
          {:error, "Missing required field in response: #{field}"}
        end

      %{type: :field_type, field: field, expected_type: type} ->
        value = Map.get(parsed, field)
        if validate_field_type(value, type) do
          :ok
        else
          {:error, "Field #{field} has incorrect type, expected #{type}"}
        end

      _ ->
        :ok
    end
  end

  defp validate_field_type(value, :string), do: is_binary(value)
  defp validate_field_type(value, :number), do: is_number(value)
  defp validate_field_type(value, :boolean), do: is_boolean(value)
  defp validate_field_type(value, :list), do: is_list(value)
  defp validate_field_type(value, :map), do: is_map(value)
  defp validate_field_type(_, _), do: true

  defp analyze_optimization_data(optimization_data, agent_type) do
    # Analyze performance metrics and feedback to suggest optimizations
    optimizations = %{}

    # Check response time performance
    optimizations = case Map.get(optimization_data, :avg_response_time_ms) do
      time when is_number(time) and time > 5000 ->
        Map.put(optimizations, :reduce_prompt_length, true)
      _ ->
        optimizations
    end

    # Check success rate
    optimizations = case Map.get(optimization_data, :success_rate) do
      rate when is_number(rate) and rate < 0.8 ->
        Map.put(optimizations, :improve_validation_rules, true)
      _ ->
        optimizations
    end

    # Agent-specific optimizations
    optimizations = case agent_type do
      :reflection ->
        Map.put(optimizations, :add_reflection_specific_prompts, true)
      :refinement ->
        Map.put(optimizations, :add_iterative_improvement_hints, true)
      _ ->
        optimizations
    end

    {:ok, optimizations}
  end

  defp apply_optimizations(template, optimizations) do
    optimized_template = Enum.reduce(optimizations, template, fn {optimization, _value}, acc ->
      apply_single_optimization(acc, optimization)
    end)

    # Update version and metadata
    updated_template = %{optimized_template |
      metadata: Map.merge(optimized_template.metadata, %{
        last_optimized: DateTime.utc_now(),
        version: increment_version(optimized_template.metadata.version),
        optimizations_applied: Map.keys(optimizations)
      })
    }

    {:ok, updated_template}
  end

  defp apply_single_optimization(template, optimization) do
    case optimization do
      :reduce_prompt_length ->
        # Add hint to keep prompts concise
        hints = Map.put(template.optimization_hints, :max_prompt_length,
                       max(1000, template.optimization_hints.max_prompt_length - 500))
        %{template | optimization_hints: hints}

      :improve_validation_rules ->
        # Add more strict validation rules
        new_rules = [
          %{type: :max_length, value: 2000},
          %{type: :required_content, value: "analysis"}
        ]
        %{template | validation_rules: template.validation_rules ++ new_rules}

      :add_reflection_specific_prompts ->
        # Add reflection-specific guidance to template
        enhanced_template = template.template <> "\n\nPlease provide a thorough reflection on your analysis."
        %{template | template: enhanced_template}

      :add_iterative_improvement_hints ->
        # Add iterative improvement guidance
        enhanced_template = template.template <> "\n\nConsider how this could be improved in the next iteration."
        %{template | template: enhanced_template}

      _ ->
        template
    end
  end

  defp filter_by_agent_type(templates, nil), do: templates
  defp filter_by_agent_type(templates, agent_type) do
    Enum.filter(templates, fn template ->
      template.metadata.agent_type == agent_type
    end)
  end

  defp apply_filters(templates, filters) do
    Enum.reduce(filters, templates, fn {filter_key, filter_value}, acc ->
      case filter_key do
        :name_contains ->
          Enum.filter(acc, fn template ->
            String.contains?(String.downcase(template.name), String.downcase(filter_value))
          end)

        :created_after ->
          Enum.filter(acc, fn template ->
            DateTime.compare(template.metadata.created_at, filter_value) != :lt
          end)

        _ ->
          acc
      end
    end)
  end

  defp generate_template_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  defp increment_version(version) do
    case String.split(version, ".") do
      [major, minor, patch] ->
        new_patch = String.to_integer(patch) + 1
        "#{major}.#{minor}.#{new_patch}"
      _ ->
        "1.0.1"
    end
  end
end
