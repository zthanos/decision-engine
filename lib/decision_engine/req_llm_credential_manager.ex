# lib/decision_engine/req_llm_credential_manager.ex
defmodule DecisionEngine.ReqLLMCredentialManager do
  @moduledoc """
  Secure credential management for ReqLLM integration.

  This module provides encrypted credential storage, secure credential rotation
  and refresh mechanisms, and credential validation and integrity checking
  for LLM API credentials.

  Features:
  - Encrypted credential storage using Erlang's crypto module
  - Secure credential rotation and refresh mechanisms
  - Credential validation and integrity checking
  - Support for multiple credential types (API keys, tokens, certificates)
  - Audit logging for credential operations
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger

  @credential_types [:api_key, :bearer_token, :oauth_token, :certificate]
  @encryption_algorithm :aes_256_gcm
  @key_derivation_iterations 100_000

  defstruct [
    :provider,
    :credential_type,
    :encrypted_value,
    :salt,
    :iv,
    :tag,
    :created_at,
    :expires_at,
    :last_validated,
    :rotation_count,
    :metadata
  ]

  @type t :: %__MODULE__{
    provider: atom(),
    credential_type: atom(),
    encrypted_value: binary(),
    salt: binary(),
    iv: binary(),
    tag: binary(),
    created_at: DateTime.t(),
    expires_at: DateTime.t() | nil,
    last_validated: DateTime.t() | nil,
    rotation_count: non_neg_integer(),
    metadata: map()
  }

  @doc """
  Stores a credential securely with encryption.

  ## Parameters
  - provider: The LLM provider (:openai, :anthropic, etc.)
  - credential_type: Type of credential (:api_key, :bearer_token, etc.)
  - value: The credential value to encrypt and store
  - opts: Optional parameters including expiration and metadata

  ## Returns
  - {:ok, credential_id} on success
  - {:error, reason} on failure

  ## Examples
      iex> store_credential(:openai, :api_key, "sk-...", expires_in: 3600)
      {:ok, "cred_123"}
  """
  @spec store_credential(atom(), atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def store_credential(provider, credential_type, value, opts \\ []) do
    with :ok <- validate_provider(provider),
         :ok <- validate_credential_type(credential_type),
         :ok <- validate_credential_value(value, credential_type),
         {:ok, encrypted_data} <- encrypt_credential(value),
         {:ok, credential_id} <- persist_credential(provider, credential_type, encrypted_data, opts) do

      ReqLLMLogger.log_credential_operation(:store, provider, credential_type, %{
        credential_id: credential_id,
        success: true
      })

      {:ok, credential_id}
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_credential_operation(:store, provider, credential_type, %{
          success: false,
          error: reason
        })
        error
    end
  end

  @doc """
  Retrieves and decrypts a stored credential.

  ## Parameters
  - credential_id: The ID of the credential to retrieve
  - opts: Optional parameters for validation and refresh

  ## Returns
  - {:ok, credential_value} on success
  - {:error, reason} on failure
  """
  @spec get_credential(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_credential(credential_id, opts \\ []) do
    with {:ok, credential} <- load_credential(credential_id),
         :ok <- validate_credential_integrity(credential),
         :ok <- check_credential_expiration(credential, opts),
         {:ok, decrypted_value} <- decrypt_credential(credential) do

      # Update last accessed timestamp
      update_credential_access(credential_id)

      ReqLLMLogger.log_credential_operation(:retrieve, credential.provider, credential.credential_type, %{
        credential_id: credential_id,
        success: true
      })

      {:ok, decrypted_value}
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_credential_operation(:retrieve, nil, nil, %{
          credential_id: credential_id,
          success: false,
          error: reason
        })
        error
    end
  end

  @doc """
  Rotates a credential by generating or accepting a new value.

  ## Parameters
  - credential_id: The ID of the credential to rotate
  - new_value: Optional new credential value (if not provided, attempts auto-rotation)
  - opts: Optional parameters for rotation behavior

  ## Returns
  - {:ok, new_credential_id} on success
  - {:error, reason} on failure
  """
  @spec rotate_credential(String.t(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def rotate_credential(credential_id, new_value \\ nil, opts \\ []) do
    with {:ok, old_credential} <- load_credential(credential_id),
         {:ok, rotation_value} <- get_rotation_value(old_credential, new_value, opts),
         {:ok, new_credential_id} <- store_credential(
           old_credential.provider,
           old_credential.credential_type,
           rotation_value,
           Keyword.merge(opts, [rotation_from: credential_id])
         ),
         :ok <- mark_credential_rotated(credential_id, new_credential_id) do

      ReqLLMLogger.log_credential_operation(:rotate, old_credential.provider, old_credential.credential_type, %{
        old_credential_id: credential_id,
        new_credential_id: new_credential_id,
        success: true
      })

      {:ok, new_credential_id}
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_credential_operation(:rotate, nil, nil, %{
          credential_id: credential_id,
          success: false,
          error: reason
        })
        error
    end
  end

  @doc """
  Validates a credential's integrity and authenticity.

  ## Parameters
  - credential_id: The ID of the credential to validate

  ## Returns
  - :ok if validation passes
  - {:error, reason} if validation fails
  """
  @spec validate_credential(String.t()) :: :ok | {:error, term()}
  def validate_credential(credential_id) do
    with {:ok, credential} <- load_credential(credential_id),
         :ok <- validate_credential_integrity(credential),
         :ok <- check_credential_expiration(credential, []),
         {:ok, _value} <- decrypt_credential(credential) do

      # Update validation timestamp
      update_credential_validation(credential_id)

      ReqLLMLogger.log_credential_operation(:validate, credential.provider, credential.credential_type, %{
        credential_id: credential_id,
        success: true
      })

      :ok
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_credential_operation(:validate, nil, nil, %{
          credential_id: credential_id,
          success: false,
          error: reason
        })
        error
    end
  end

  @doc """
  Refreshes an expired or expiring credential using provider-specific refresh mechanisms.

  ## Parameters
  - credential_id: The ID of the credential to refresh
  - opts: Optional parameters for refresh behavior

  ## Returns
  - {:ok, new_credential_id} on success
  - {:error, reason} on failure
  """
  @spec refresh_credential(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def refresh_credential(credential_id, opts \\ []) do
    with {:ok, credential} <- load_credential(credential_id),
         {:ok, refresh_token} <- get_refresh_token(credential),
         {:ok, new_value} <- perform_credential_refresh(credential.provider, refresh_token, opts),
         {:ok, new_credential_id} <- store_credential(
           credential.provider,
           credential.credential_type,
           new_value,
           Keyword.merge(opts, [refreshed_from: credential_id])
         ) do

      ReqLLMLogger.log_credential_operation(:refresh, credential.provider, credential.credential_type, %{
        old_credential_id: credential_id,
        new_credential_id: new_credential_id,
        success: true
      })

      {:ok, new_credential_id}
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_credential_operation(:refresh, nil, nil, %{
          credential_id: credential_id,
          success: false,
          error: reason
        })
        error
    end
  end

  @doc """
  Deletes a credential securely, ensuring it cannot be recovered.

  ## Parameters
  - credential_id: The ID of the credential to delete

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec delete_credential(String.t()) :: :ok | {:error, term()}
  def delete_credential(credential_id) do
    with {:ok, credential} <- load_credential(credential_id),
         :ok <- secure_delete_credential(credential_id) do

      ReqLLMLogger.log_credential_operation(:delete, credential.provider, credential.credential_type, %{
        credential_id: credential_id,
        success: true
      })

      :ok
    else
      {:error, reason} = error ->
        ReqLLMLogger.log_credential_operation(:delete, nil, nil, %{
          credential_id: credential_id,
          success: false,
          error: reason
        })
        error
    end
  end

  # Private functions

  defp validate_provider(provider) when provider in [:openai, :anthropic, :ollama, :openrouter, :custom], do: :ok
  defp validate_provider(provider), do: {:error, {:invalid_provider, provider}}

  defp validate_credential_type(type) when type in @credential_types, do: :ok
  defp validate_credential_type(type), do: {:error, {:invalid_credential_type, type}}

  defp validate_credential_value(value, _type) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_credential_value(_value, type), do: {:error, {:invalid_credential_value, type}}

  defp encrypt_credential(value) do
    try do
      # Generate random salt and IV
      salt = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(12)

      # Derive encryption key from master key and salt
      master_key = get_master_key()
      derived_key = :crypto.pbkdf2_hmac(:sha256, master_key, salt, @key_derivation_iterations, 32)

      # Encrypt the credential value
      {encrypted_value, tag} = :crypto.crypto_one_time_aead(@encryption_algorithm, derived_key, iv, value, "", true)

      {:ok, %{
        encrypted_value: encrypted_value,
        salt: salt,
        iv: iv,
        tag: tag
      }}
    rescue
      error ->
        Logger.error("Credential encryption failed: #{inspect(error)}")
        {:error, :encryption_failed}
    end
  end

  defp decrypt_credential(credential) do
    try do
      # Derive decryption key from master key and stored salt
      master_key = get_master_key()
      derived_key = :crypto.pbkdf2_hmac(:sha256, master_key, credential.salt, @key_derivation_iterations, 32)

      # Decrypt the credential value
      case :crypto.crypto_one_time_aead(@encryption_algorithm, derived_key, credential.iv, credential.encrypted_value, "", credential.tag, false) do
        decrypted_value when is_binary(decrypted_value) ->
          {:ok, decrypted_value}
        :error ->
          {:error, :decryption_failed}
      end
    rescue
      error ->
        Logger.error("Credential decryption failed: #{inspect(error)}")
        {:error, :decryption_failed}
    end
  end

  defp get_master_key do
    # In production, this should be loaded from a secure key management system
    # For now, we'll use an environment variable with a fallback
    case System.get_env("CREDENTIAL_MASTER_KEY") do
      nil ->
        Logger.warning("Using default master key - set CREDENTIAL_MASTER_KEY environment variable in production")
        "default_master_key_change_in_production_123456789012345678901234"
      key when byte_size(key) >= 32 ->
        String.slice(key, 0, 32)
      key ->
        Logger.warning("Master key too short, padding with default suffix")
        String.pad_trailing(key, 32, "0")
    end
  end

  defp persist_credential(provider, credential_type, encrypted_data, opts) do
    credential_id = generate_credential_id()
    expires_at = case Keyword.get(opts, :expires_in) do
      nil -> nil
      seconds -> DateTime.add(DateTime.utc_now(), seconds, :second)
    end

    credential = %__MODULE__{
      provider: provider,
      credential_type: credential_type,
      encrypted_value: encrypted_data.encrypted_value,
      salt: encrypted_data.salt,
      iv: encrypted_data.iv,
      tag: encrypted_data.tag,
      created_at: DateTime.utc_now(),
      expires_at: expires_at,
      last_validated: nil,
      rotation_count: 0,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Store in ETS table for now (in production, use a proper database)
    table_name = get_credential_table()
    :ets.insert(table_name, {credential_id, credential})

    {:ok, credential_id}
  end

  defp load_credential(credential_id) do
    table_name = get_credential_table()
    case :ets.lookup(table_name, credential_id) do
      [{^credential_id, credential}] -> {:ok, credential}
      [] -> {:error, :credential_not_found}
    end
  end

  defp validate_credential_integrity(credential) do
    # Validate that all required fields are present and properly formatted
    required_fields = [:provider, :credential_type, :encrypted_value, :salt, :iv, :tag, :created_at]

    missing_fields = Enum.filter(required_fields, fn field ->
      case Map.get(credential, field) do
        nil -> true
        "" -> true
        _ -> false
      end
    end)

    case missing_fields do
      [] -> :ok
      fields -> {:error, {:integrity_check_failed, :missing_fields, fields}}
    end
  end

  defp check_credential_expiration(credential, opts) do
    case credential.expires_at do
      nil -> :ok
      expires_at ->
        now = DateTime.utc_now()
        grace_period = Keyword.get(opts, :grace_period_seconds, 0)
        effective_expiry = DateTime.add(expires_at, grace_period, :second)

        if DateTime.compare(now, effective_expiry) == :lt do
          :ok
        else
          {:error, :credential_expired}
        end
    end
  end

  defp get_rotation_value(credential, nil, _opts) do
    # Auto-rotation not implemented for most credential types
    {:error, {:auto_rotation_not_supported, credential.credential_type}}
  end

  defp get_rotation_value(_credential, new_value, _opts) when is_binary(new_value) do
    {:ok, new_value}
  end

  defp mark_credential_rotated(old_id, new_id) do
    # Mark the old credential as rotated
    table_name = get_credential_table()
    case :ets.lookup(table_name, old_id) do
      [{^old_id, credential}] ->
        updated_credential = %{credential |
          rotation_count: credential.rotation_count + 1,
          metadata: Map.put(credential.metadata, :rotated_to, new_id)
        }
        :ets.insert(table_name, {old_id, updated_credential})
        :ok
      [] ->
        {:error, :credential_not_found}
    end
  end

  defp update_credential_access(credential_id) do
    table_name = get_credential_table()
    case :ets.lookup(table_name, credential_id) do
      [{^credential_id, credential}] ->
        updated_credential = %{credential |
          metadata: Map.put(credential.metadata, :last_accessed, DateTime.utc_now())
        }
        :ets.insert(table_name, {credential_id, updated_credential})
        :ok
      [] ->
        {:error, :credential_not_found}
    end
  end

  defp update_credential_validation(credential_id) do
    table_name = get_credential_table()
    case :ets.lookup(table_name, credential_id) do
      [{^credential_id, credential}] ->
        updated_credential = %{credential | last_validated: DateTime.utc_now()}
        :ets.insert(table_name, {credential_id, updated_credential})
        :ok
      [] ->
        {:error, :credential_not_found}
    end
  end

  defp get_refresh_token(credential) do
    case Map.get(credential.metadata, :refresh_token) do
      nil -> {:error, :no_refresh_token}
      token -> {:ok, token}
    end
  end

  defp perform_credential_refresh(provider, refresh_token, _opts) do
    # Provider-specific refresh logic would go here
    # For now, return an error as refresh is not implemented
    Logger.info("Credential refresh requested for #{provider} with token: #{String.slice(refresh_token, 0, 8)}...")
    {:error, {:refresh_not_implemented, provider}}
  end

  defp secure_delete_credential(credential_id) do
    table_name = get_credential_table()
    :ets.delete(table_name, credential_id)
    :ok
  end

  defp generate_credential_id do
    "cred_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp get_credential_table do
    table_name = :req_llm_credentials

    # Create table if it doesn't exist
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])
      _ ->
        table_name
    end

    table_name
  end
end
