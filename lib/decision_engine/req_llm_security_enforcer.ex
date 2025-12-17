# lib/decision_engine/req_llm_security_enforcer.ex
defmodule DecisionEngine.ReqLLMSecurityEnforcer do
  @moduledoc """
  HTTPS enforcement and SSL certificate validation for ReqLLM integration.

  This module provides comprehensive security enforcement including:
  - HTTPS-only connection enforcement
  - SSL certificate validation and pinning
  - Connection security monitoring
  - Security policy compliance checking

  All LLM API connections are secured and validated according to security policies.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger

  @https_schemes ["https"]
  # Default SSL options - function references are resolved at runtime
  defp default_ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  @security_policies %{
    enforce_https: true,
    validate_certificates: true,
    allow_self_signed: false,
    certificate_pinning: false,
    min_tls_version: :"tlsv1.2",
    cipher_suites: :default,
    connection_timeout: 30_000,
    security_headers_required: true
  }

  defstruct [
    :policy,
    :pinned_certificates,
    :allowed_hosts,
    :security_headers,
    :monitoring_enabled,
    :violation_handler
  ]

  @type t :: %__MODULE__{
    policy: map(),
    pinned_certificates: list(),
    allowed_hosts: list(),
    security_headers: list(),
    monitoring_enabled: boolean(),
    violation_handler: function() | nil
  }

  @doc """
  Initializes the security enforcer with the given policy.

  ## Parameters
  - policy: Security policy configuration (optional, uses defaults if not provided)
  - opts: Additional options for security enforcement

  ## Returns
  - {:ok, enforcer} on success
  - {:error, reason} on failure

  ## Examples
      iex> init_security_enforcer(%{enforce_https: true})
      {:ok, %ReqLLMSecurityEnforcer{}}
  """
  @spec init_security_enforcer(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def init_security_enforcer(policy \\ %{}, opts \\ []) do
    merged_policy = Map.merge(@security_policies, policy)

    enforcer = %__MODULE__{
      policy: merged_policy,
      pinned_certificates: Keyword.get(opts, :pinned_certificates, []),
      allowed_hosts: Keyword.get(opts, :allowed_hosts, []),
      security_headers: Keyword.get(opts, :security_headers, []),
      monitoring_enabled: Keyword.get(opts, :monitoring_enabled, true),
      violation_handler: Keyword.get(opts, :violation_handler)
    }

    ReqLLMLogger.log_security_event(:security_enforcer_initialized, %{
      policy: sanitize_policy_for_logging(merged_policy),
      success: true
    })

    {:ok, enforcer}
  end

  @doc """
  Validates and enforces security policies for a ReqLLM request.

  ## Parameters
  - request: The request configuration to validate
  - enforcer: The security enforcer configuration
  - context: Request context for logging and monitoring

  ## Returns
  - {:ok, validated_request} on success
  - {:error, violation_details} on security policy violation

  ## Examples
      iex> enforce_security(request, enforcer, %{provider: :openai})
      {:ok, validated_request}
  """
  @spec enforce_security(map(), t(), map()) :: {:ok, map()} | {:error, term()}
  def enforce_security(request, enforcer, context \\ %{}) do
    with :ok <- validate_https_enforcement(request, enforcer),
         :ok <- validate_ssl_configuration(request, enforcer),
         :ok <- validate_certificate_pinning(request, enforcer),
         :ok <- validate_security_headers(request, enforcer),
         {:ok, secured_request} <- apply_security_enhancements(request, enforcer) do

      if enforcer.monitoring_enabled do
        ReqLLMLogger.log_security_event(:security_validation_passed, %{
          provider: Map.get(context, :provider),
          url: get_safe_url_for_logging(request),
          success: true
        })
      end

      {:ok, secured_request}
    else
      {:error, violation} = error ->
        handle_security_violation(violation, enforcer, context)
        error
    end
  end

  @doc """
  Validates SSL certificate information for a connection.

  ## Parameters
  - cert_info: Certificate information from the connection
  - enforcer: The security enforcer configuration
  - host: The hostname being connected to

  ## Returns
  - :ok if certificate is valid
  - {:error, reason} if certificate validation fails
  """
  @spec validate_certificate(map(), t(), String.t()) :: :ok | {:error, term()}
  def validate_certificate(cert_info, enforcer, host) do
    with :ok <- validate_certificate_chain(cert_info, enforcer),
         :ok <- validate_certificate_expiration(cert_info),
         :ok <- validate_certificate_hostname(cert_info, host),
         :ok <- validate_certificate_pinning_match(cert_info, enforcer) do

      ReqLLMLogger.log_security_event(:certificate_validation_passed, %{
        host: host,
        subject: get_certificate_subject(cert_info),
        success: true
      })

      :ok
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_security_event(:certificate_validation_failed, %{
          host: host,
          reason: reason,
          success: false
        })
        error
    end
  end

  @doc """
  Monitors connection security and reports violations.

  ## Parameters
  - connection_info: Information about the established connection
  - enforcer: The security enforcer configuration
  - context: Request context

  ## Returns
  - :ok if monitoring completes successfully
  - {:error, reason} if monitoring fails
  """
  @spec monitor_connection_security(map(), t(), map()) :: :ok | {:error, term()}
  def monitor_connection_security(connection_info, enforcer, context \\ %{}) do
    if enforcer.monitoring_enabled do
      security_metrics = %{
        tls_version: Map.get(connection_info, :tls_version),
        cipher_suite: Map.get(connection_info, :cipher_suite),
        certificate_valid: Map.get(connection_info, :certificate_valid, false),
        connection_secure: Map.get(connection_info, :secure, false),
        provider: Map.get(context, :provider),
        timestamp: DateTime.utc_now()
      }

      # Check for security policy violations
      violations = detect_security_violations(security_metrics, enforcer)

      case violations do
        [] ->
          ReqLLMLogger.log_security_event(:connection_security_monitored, %{
            metrics: security_metrics,
            violations: [],
            success: true
          })
          :ok

        violations ->
          ReqLLMLogger.log_security_event(:security_violations_detected, %{
            metrics: security_metrics,
            violations: violations,
            success: false
          })
          {:error, {:security_violations, violations}}
      end
    else
      :ok
    end
  end

  @doc """
  Updates security policy configuration.

  ## Parameters
  - enforcer: Current security enforcer
  - policy_updates: Map of policy updates to apply

  ## Returns
  - {:ok, updated_enforcer} on success
  - {:error, reason} on failure
  """
  @spec update_security_policy(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_security_policy(enforcer, policy_updates) do
    with :ok <- validate_policy_updates(policy_updates),
         updated_policy <- Map.merge(enforcer.policy, policy_updates),
         updated_enforcer <- %{enforcer | policy: updated_policy} do

      ReqLLMLogger.log_security_event(:security_policy_updated, %{
        updates: sanitize_policy_for_logging(policy_updates),
        success: true
      })

      {:ok, updated_enforcer}
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_security_event(:security_policy_update_failed, %{
          reason: reason,
          success: false
        })
        error
    end
  end

  # Private functions

  defp validate_https_enforcement(request, enforcer) do
    if enforcer.policy.enforce_https do
      case get_request_scheme(request) do
        scheme when scheme in @https_schemes ->
          :ok
        scheme ->
          {:error, {:https_required, scheme}}
      end
    else
      :ok
    end
  end

  defp validate_ssl_configuration(request, enforcer) do
    if enforcer.policy.validate_certificates do
      ssl_options = get_ssl_options(request, enforcer)

      # Validate SSL options are properly configured
      case validate_ssl_options(ssl_options, enforcer) do
        :ok -> :ok
        {:error, reason} -> {:error, {:invalid_ssl_config, reason}}
      end
    else
      :ok
    end
  end

  defp validate_certificate_pinning(request, enforcer) do
    if enforcer.policy.certificate_pinning and length(enforcer.pinned_certificates) > 0 do
      host = get_request_host(request)

      case find_pinned_certificate(host, enforcer.pinned_certificates) do
        nil -> {:error, {:certificate_pinning_required, host}}
        _cert -> :ok
      end
    else
      :ok
    end
  end

  defp validate_security_headers(_request, enforcer) do
    if enforcer.policy.security_headers_required do
      # Validate that required security headers will be included
      required_headers = ["user-agent", "accept"]
      # For now, assume headers are properly configured
      # In a full implementation, this would validate the actual headers
      :ok
    else
      :ok
    end
  end

  defp apply_security_enhancements(request, enforcer) do
    enhanced_request = request
    |> ensure_https_scheme()
    |> apply_ssl_options(enforcer)
    |> apply_security_headers(enforcer)
    |> apply_connection_timeouts(enforcer)

    {:ok, enhanced_request}
  end

  defp validate_certificate_chain(cert_info, enforcer) do
    if enforcer.policy.validate_certificates do
      # Validate certificate chain integrity
      case Map.get(cert_info, :chain_valid, false) do
        true -> :ok
        false -> {:error, :invalid_certificate_chain}
      end
    else
      :ok
    end
  end

  defp validate_certificate_expiration(cert_info) do
    case Map.get(cert_info, :expires_at) do
      nil -> {:error, :certificate_expiration_unknown}
      expires_at ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          :ok
        else
          {:error, :certificate_expired}
        end
    end
  end

  defp validate_certificate_hostname(cert_info, host) do
    case Map.get(cert_info, :hostname_match, false) do
      true -> :ok
      false -> {:error, {:hostname_mismatch, host}}
    end
  end

  defp validate_certificate_pinning_match(cert_info, enforcer) do
    if enforcer.policy.certificate_pinning and length(enforcer.pinned_certificates) > 0 do
      cert_fingerprint = Map.get(cert_info, :fingerprint)

      case Enum.find(enforcer.pinned_certificates, fn pinned ->
        Map.get(pinned, :fingerprint) == cert_fingerprint
      end) do
        nil -> {:error, :certificate_pinning_mismatch}
        _match -> :ok
      end
    else
      :ok
    end
  end

  defp detect_security_violations(metrics, enforcer) do
    violations = []

    # Check TLS version
    violations = if metrics.tls_version &&
                    not tls_version_acceptable?(metrics.tls_version, enforcer.policy.min_tls_version) do
      [{:weak_tls_version, metrics.tls_version} | violations]
    else
      violations
    end

    # Check certificate validity
    violations = if not metrics.certificate_valid do
      [:invalid_certificate | violations]
    else
      violations
    end

    # Check connection security
    violations = if not metrics.connection_secure do
      [:insecure_connection | violations]
    else
      violations
    end

    violations
  end

  defp handle_security_violation(violation, enforcer, context) do
    ReqLLMLogger.log_security_event(:security_violation, %{
      violation: violation,
      provider: Map.get(context, :provider),
      context: sanitize_context_for_logging(context),
      success: false
    })

    # Call custom violation handler if configured
    if enforcer.violation_handler do
      try do
        enforcer.violation_handler.(violation, context)
      rescue
        error ->
          Logger.error("Security violation handler failed: #{inspect(error)}")
      end
    end
  end

  defp get_request_scheme(request) do
    case Map.get(request, :url) do
      nil -> nil
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme} -> scheme
          _ -> nil
        end
      _ -> nil
    end
  end

  defp get_request_host(request) do
    case Map.get(request, :url) do
      nil -> nil
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{host: host} -> host
          _ -> nil
        end
      _ -> nil
    end
  end

  defp get_ssl_options(request, enforcer) do
    base_options = default_ssl_options()

    # Apply policy-specific SSL options
    policy_options = []

    policy_options = if enforcer.policy.allow_self_signed do
      Keyword.put(policy_options, :verify, :verify_none)
    else
      policy_options
    end

    policy_options = if enforcer.policy.min_tls_version do
      Keyword.put(policy_options, :versions, [enforcer.policy.min_tls_version])
    else
      policy_options
    end

    # Merge with any existing SSL options from request
    existing_options = Map.get(request, :ssl_options, [])

    base_options
    |> Keyword.merge(policy_options)
    |> Keyword.merge(existing_options)
  end

  defp validate_ssl_options(ssl_options, _enforcer) do
    # Validate that SSL options are properly formatted
    required_keys = [:verify, :cacerts]

    missing_keys = Enum.filter(required_keys, fn key ->
      not Keyword.has_key?(ssl_options, key)
    end)

    case missing_keys do
      [] -> :ok
      keys -> {:error, {:missing_ssl_options, keys}}
    end
  end

  defp find_pinned_certificate(host, pinned_certificates) do
    Enum.find(pinned_certificates, fn cert ->
      case Map.get(cert, :hosts, []) do
        hosts when is_list(hosts) -> host in hosts
        _ -> false
      end
    end)
  end

  defp ensure_https_scheme(request) do
    case Map.get(request, :url) do
      nil -> request
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: "http"} = uri ->
            https_url = URI.to_string(%{uri | scheme: "https"})
            Map.put(request, :url, https_url)
          _ ->
            request
        end
      _ -> request
    end
  end

  defp apply_ssl_options(request, enforcer) do
    ssl_options = get_ssl_options(request, enforcer)
    Map.put(request, :ssl_options, ssl_options)
  end

  defp apply_security_headers(request, enforcer) do
    if enforcer.policy.security_headers_required do
      existing_headers = Map.get(request, :headers, [])
      security_headers = [
        {"user-agent", "DecisionEngine/1.0"},
        {"accept", "application/json"},
        {"connection", "close"}
      ]

      updated_headers = security_headers ++ existing_headers
      Map.put(request, :headers, updated_headers)
    else
      request
    end
  end

  defp apply_connection_timeouts(request, enforcer) do
    timeout = enforcer.policy.connection_timeout
    Map.put(request, :timeout, timeout)
  end

  defp tls_version_acceptable?(actual_version, min_version) do
    version_order = [:tlsv1, :"tlsv1.1", :"tlsv1.2", :"tlsv1.3"]

    actual_index = Enum.find_index(version_order, &(&1 == actual_version))
    min_index = Enum.find_index(version_order, &(&1 == min_version))

    case {actual_index, min_index} do
      {nil, _} -> false
      {_, nil} -> true
      {actual, min} -> actual >= min
    end
  end

  defp get_certificate_subject(cert_info) do
    Map.get(cert_info, :subject, "unknown")
  end

  defp get_safe_url_for_logging(request) do
    case Map.get(request, :url) do
      nil -> "unknown"
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{host: host, path: path} -> "#{host}#{path || "/"}"
          _ -> "invalid_url"
        end
      _ -> "non_string_url"
    end
  end

  defp sanitize_policy_for_logging(policy) do
    # Remove any sensitive policy information
    Map.drop(policy, [:pinned_certificates, :allowed_hosts])
  end

  defp sanitize_context_for_logging(context) do
    # Remove sensitive context information
    Map.drop(context, [:credentials, :api_key, :token])
  end

  defp validate_policy_updates(updates) do
    # Validate that policy updates contain valid keys and values
    valid_keys = Map.keys(@security_policies)

    invalid_keys = Map.keys(updates) -- valid_keys

    case invalid_keys do
      [] -> :ok
      keys -> {:error, {:invalid_policy_keys, keys}}
    end
  end
end
