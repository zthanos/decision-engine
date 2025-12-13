# lib/decision_engine_web/live/decision_live/settings.ex
defmodule DecisionEngineWeb.DecisionLive.Settings do
  use DecisionEngineWeb, :live_view
  alias DecisionEngine.LLMConfigManager

  @impl true
  def mount(_params, _session, socket) do
    # Default configuration with all required fields
    default_config = %{
      provider: "openai",
      model: "gpt-4",
      endpoint: "https://api.openai.com/v1/chat/completions",
      streaming: true,
      temperature: 0.7,
      max_tokens: 2000,
      timeout: 30000
    }

    # Load current configuration and merge with defaults
    {config, api_key_status} = case LLMConfigManager.load_config() do
      {:ok, loaded_config} ->
        # Merge loaded config with defaults to ensure all fields are present
        merged_config = Map.merge(default_config, loaded_config)

        # Check API key status based on provider requirements
        api_key_status = if provider_requires_api_key?(merged_config.provider) do
          case LLMConfigManager.get_api_key() do
            {:ok, _} -> :available
            {:error, :not_found} -> :required
          end
        else
          :optional
        end
        {merged_config, api_key_status}

      {:error, _} ->
        # Determine API key status for default provider
        api_key_status = if provider_requires_api_key?(default_config.provider) do
          :required
        else
          :optional
        end
        {default_config, api_key_status}
    end

    {:ok,
     socket
     |> assign(:config, config)
     |> assign(:api_key, "")
     |> assign(:api_key_status, api_key_status)
     |> assign(:saved, false)
     |> assign(:errors, [])
     |> assign(:testing_connection, false)
     |> assign(:connection_result, nil)
     |> assign(:show_api_key, false)}
  end

  @impl true
  def handle_event("update_config", %{"config" => config_params}, socket) do
    current_config = socket.assigns.config

    # Convert string keys to atoms and parse numeric values
    new_config = %{
      provider: config_params["provider"],
      model: config_params["model"],
      endpoint: config_params["endpoint"],
      streaming: config_params["streaming"] == "true",
      temperature: parse_float(config_params["temperature"], 0.7),
      max_tokens: parse_integer(config_params["max_tokens"], 2000),
      timeout: parse_integer(config_params["timeout"], 30) * 1000  # Convert seconds to milliseconds
    }

    # If provider changed, update model and endpoint to defaults for that provider
    final_config = if new_config.provider != current_config.provider do
      provider_defaults = get_provider_defaults(new_config.provider)
      Map.merge(new_config, provider_defaults)
    else
      new_config
    end

    # Update API key status based on provider
    api_key_status = if provider_requires_api_key?(final_config.provider) do
      if String.trim(socket.assigns.api_key) != "", do: :available, else: :required
    else
      :optional
    end

    {:noreply,
     socket
     |> assign(:config, final_config)
     |> assign(:api_key_status, api_key_status)}
  end

  @impl true
  def handle_event("update_api_key", %{"api_key" => api_key}, socket) do
    {:noreply, assign(socket, :api_key, api_key)}
  end

  @impl true
  def handle_event("toggle_api_key_visibility", _params, socket) do
    {:noreply, assign(socket, :show_api_key, !socket.assigns.show_api_key)}
  end

  @impl true
  def handle_event("save_config", _params, socket) do
    config = socket.assigns.config
    api_key = socket.assigns.api_key

    # Check if API key is required for this provider
    api_key_required = provider_requires_api_key?(config.provider)
    api_key_provided = String.trim(api_key) != ""

    # Validate that API key is provided if required
    if api_key_required and not api_key_provided do
      {:noreply, assign(socket, :errors, ["API key is required for #{config.provider}"])}
    else
      # Validate configuration
      case LLMConfigManager.validate_config(config) do
        :ok ->
          # Save configuration (excluding API key)
          case LLMConfigManager.save_config(config) do
            :ok ->
              # Save API key to session storage if provided
              if api_key_provided do
                LLMConfigManager.set_api_key(config.provider, String.trim(api_key))
              end

              # Determine API key status
              api_key_status = cond do
                not api_key_required -> :optional
                api_key_provided -> :available
                true -> :required
              end

              {:noreply,
               socket
               |> assign(:saved, true)
               |> assign(:errors, [])
               |> assign(:api_key_status, api_key_status)}

            {:error, reason} ->
              {:noreply, assign(socket, :errors, ["Failed to save configuration: #{inspect(reason)}"])}
          end

        {:error, errors} ->
          {:noreply, assign(socket, :errors, errors)}
      end
    end
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    config = socket.assigns.config
    api_key = socket.assigns.api_key

    # Check if API key is required for this provider
    api_key_required = provider_requires_api_key?(config.provider)
    api_key_provided = String.trim(api_key) != ""

    if api_key_required and not api_key_provided do
      {:noreply, assign(socket, :errors, ["API key is required for connection testing with #{config.provider}"])}
    else
      # Start connection test
      send(self(), {:test_connection, config, api_key})

      {:noreply,
       socket
       |> assign(:testing_connection, true)
       |> assign(:connection_result, nil)
       |> assign(:errors, [])}
    end
  end

  @impl true
  def handle_event("clear_messages", _params, socket) do
    {:noreply,
     socket
     |> assign(:saved, false)
     |> assign(:errors, [])
     |> assign(:connection_result, nil)}
  end

  @impl true
  def handle_info({:test_connection, config, api_key}, socket) do
    # Test connection in background
    test_config = Map.put(config, :api_key, api_key)

    result = case LLMConfigManager.test_connection(test_config) do
      :ok -> {:success, "Connection successful! LLM provider is responding correctly."}
      {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
    end

    {:noreply,
     socket
     |> assign(:testing_connection, false)
     |> assign(:connection_result, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="navbar bg-primary text-primary-content shadow-lg">
        <div class="flex-1">
          <.logo_with_text
            class="btn btn-ghost text-xl"
            size="h-6 w-auto"
            text="Decision Engine"
            href="/"
          />
        </div>
        <div class="flex-none gap-2">
          <.nav_link navigate="/" class="btn btn-ghost btn-sm">
            <span class="hero-home w-5 h-5"></span>
            Home
          </.nav_link>
          <.nav_link navigate="/domains" class="btn btn-ghost btn-sm">
            <span class="hero-building-office w-5 h-5"></span>
            Domains
          </.nav_link>
          <.nav_link navigate="/history" class="btn btn-ghost btn-sm">
            <span class="hero-clock w-5 h-5"></span>
            History
          </.nav_link>
          <.nav_link navigate="/settings" class="btn btn-ghost btn-sm btn-active">
            <span class="hero-cog-6-tooth w-5 h-5"></span>
            Settings
          </.nav_link>
        </div>
      </div>

      <div class="container mx-auto p-6 max-w-4xl">
        <h1 class="text-3xl font-bold mb-6">
          <span class="hero-cog-6-tooth w-8 h-8 inline"></span>
          Settings
        </h1>

        <!-- Success Message -->
        <%= if @saved do %>
          <div class="alert alert-success shadow-lg mb-6">
            <span class="hero-check-circle w-6 h-6"></span>
            <span>Configuration saved successfully!</span>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="clear_messages"
              aria-label="Dismiss success message"
            >
              ✕
            </button>
          </div>
        <% end %>

        <!-- Error Messages -->
        <%= if length(@errors) > 0 do %>
          <div class="alert alert-error shadow-lg mb-6">
            <span class="hero-exclamation-triangle w-6 h-6"></span>
            <div>
              <h3 class="font-bold">Configuration Errors:</h3>
              <ul class="list-disc list-inside">
                <%= for error <- @errors do %>
                  <li><%= error %></li>
                <% end %>
              </ul>
            </div>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="clear_messages"
              aria-label="Dismiss error messages"
            >
              ✕
            </button>
          </div>
        <% end %>

        <!-- Connection Test Result -->
        <%= if @connection_result do %>
          <div class={"alert shadow-lg mb-6 #{if elem(@connection_result, 0) == :success, do: "alert-success", else: "alert-error"}"}>
            <span class={"w-6 h-6 #{if elem(@connection_result, 0) == :success, do: "hero-check-circle", else: "hero-exclamation-triangle"}"}></span>
            <span><%= elem(@connection_result, 1) %></span>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="clear_messages"
              aria-label="Dismiss connection result"
            >
              ✕
            </button>
          </div>
        <% end %>

        <!-- LLM Configuration Form -->
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title">
              <span class="hero-cpu-chip w-6 h-6"></span>
              LLM Configuration
            </h2>
            <p class="text-sm text-base-content/70 mb-6">
              Configure your Large Language Model settings. API keys are stored only in memory and must be re-entered each session for security.
            </p>

            <form phx-change="update_config" phx-submit="save_config" class="space-y-6">
              <!-- Provider Selection -->
              <div class="form-control">
                <label class="label" for="provider">
                  <span class="label-text font-semibold">Provider</span>
                </label>
                <select
                  id="provider"
                  name="config[provider]"
                  class="select select-bordered w-full"
                  required
                >
                  <option value="openai" selected={@config.provider == "openai"}>OpenAI</option>
                  <option value="anthropic" selected={@config.provider == "anthropic"}>Anthropic Claude</option>
                  <option value="ollama" selected={@config.provider == "ollama"}>Ollama (Local)</option>
                  <option value="lm_studio" selected={@config.provider == "lm_studio"}>LM Studio (Local)</option>
                  <option value="openrouter" selected={@config.provider == "openrouter"}>OpenRouter</option>
                  <option value="custom" selected={@config.provider == "custom"}>Custom Provider</option>
                </select>
              </div>

              <!-- Model Selection -->
              <div class="form-control">
                <label class="label" for="model">
                  <span class="label-text font-semibold">Model</span>
                </label>
                <input
                  type="text"
                  id="model"
                  name="config[model]"
                  class="input input-bordered w-full"
                  value={@config.model}
                  placeholder="e.g., gpt-4, claude-3-sonnet-20240229"
                  required
                />
                <label class="label">
                  <span class="label-text-alt">Specify the exact model name for your provider</span>
                </label>
              </div>

              <!-- API Endpoint -->
              <div class="form-control">
                <label class="label" for="endpoint">
                  <span class="label-text font-semibold">API Endpoint</span>
                </label>
                <input
                  type="url"
                  id="endpoint"
                  name="config[endpoint]"
                  class="input input-bordered w-full"
                  value={@config.endpoint}
                  placeholder="https://api.openai.com/v1/chat/completions"
                  required
                />
                <label class="label">
                  <span class="label-text-alt">Full URL to the chat completions endpoint</span>
                </label>
              </div>

              <!-- API Key -->
              <div class="form-control">
                <label class="label" for="api_key">
                  <span class="label-text font-semibold">API Key</span>
                  <span class={"badge badge-sm #{
                    case @api_key_status do
                      :available -> "badge-success"
                      :optional -> "badge-info"
                      :required -> "badge-warning"
                    end
                  }"}>
                    <%= case @api_key_status do
                      :available -> "Available"
                      :optional -> "Optional"
                      :required -> "Required"
                    end %>
                  </span>
                </label>
                <div class="input-group">
                  <input
                    type={if @show_api_key, do: "text", else: "password"}
                    id="api_key"
                    name="api_key"
                    class="input input-bordered flex-1"
                    value={@api_key}
                    placeholder={
                      if @api_key_status == :optional,
                        do: "API key not required for local providers",
                        else: "Enter your API key..."
                    }
                    phx-change="update_api_key"
                    autocomplete="off"
                  />
                  <button
                    type="button"
                    class="btn btn-square btn-outline"
                    phx-click="toggle_api_key_visibility"
                    aria-label={if @show_api_key, do: "Hide API key", else: "Show API key"}
                  >
                    <span class={if @show_api_key, do: "hero-eye-slash w-5 h-5", else: "hero-eye w-5 h-5"}></span>
                  </button>
                </div>
                <label class="label">
                  <span class={"label-text-alt #{if @api_key_status == :optional, do: "text-info", else: "text-warning"}"}>
                    <%= if @api_key_status == :optional do %>
                      ℹ️ Local providers don't require API keys
                    <% else %>
                      ⚠️ API keys are stored only in memory and cleared on page refresh
                    <% end %>
                  </span>
                </label>
              </div>

              <!-- Advanced Settings -->
              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" />
                <div class="collapse-title text-lg font-medium">
                  Advanced Settings
                </div>
                <div class="collapse-content space-y-4">
                  <!-- Streaming -->
                  <div class="form-control">
                    <label class="label cursor-pointer">
                      <span class="label-text font-semibold">Enable Streaming</span>
                      <input
                        type="checkbox"
                        name="config[streaming]"
                        class="toggle toggle-primary"
                        checked={@config.streaming}
                        value="true"
                      />
                    </label>
                    <label class="label">
                      <span class="label-text-alt">Stream responses in real-time for better user experience</span>
                    </label>
                  </div>

                  <!-- Temperature -->
                  <div class="form-control">
                    <label class="label" for="temperature">
                      <span class="label-text font-semibold">Temperature</span>
                      <span class="label-text-alt"><%= @config.temperature %></span>
                    </label>
                    <input
                      type="range"
                      id="temperature"
                      name="config[temperature]"
                      class="range range-primary"
                      min="0"
                      max="1"
                      step="0.1"
                      value={@config.temperature}
                    />
                    <div class="w-full flex justify-between text-xs px-2">
                      <span>Focused</span>
                      <span>Balanced</span>
                      <span>Creative</span>
                    </div>
                  </div>

                  <!-- Max Tokens -->
                  <div class="form-control">
                    <label class="label" for="max_tokens">
                      <span class="label-text font-semibold">Max Tokens</span>
                    </label>
                    <input
                      type="number"
                      id="max_tokens"
                      name="config[max_tokens]"
                      class="input input-bordered w-full"
                      value={@config.max_tokens}
                      min="1"
                      max="8000"
                    />
                    <label class="label">
                      <span class="label-text-alt">Maximum response length (1-8000 tokens)</span>
                    </label>
                  </div>

                  <!-- Timeout -->
                  <div class="form-control">
                    <label class="label" for="timeout">
                      <span class="label-text font-semibold">Timeout (seconds)</span>
                    </label>
                    <input
                      type="number"
                      id="timeout"
                      name="config[timeout]"
                      class="input input-bordered w-full"
                      value={div(@config.timeout, 1000)}
                      min="5"
                      max="300"
                    />
                    <label class="label">
                      <span class="label-text-alt">Request timeout in seconds (5-300)</span>
                    </label>
                  </div>
                </div>
              </div>

              <!-- Form Actions -->
              <div class="card-actions justify-between">
                <button
                  type="button"
                  class={"btn btn-outline #{if @testing_connection, do: "loading", else: ""}"}
                  phx-click="test_connection"
                  disabled={@testing_connection or (@api_key_status == :required and String.trim(@api_key) == "")}
                >
                  <%= if @testing_connection do %>
                    Testing...
                  <% else %>
                    <span class="hero-signal w-5 h-5"></span>
                    Test Connection
                  <% end %>
                </button>

                <button type="submit" class="btn btn-primary">
                  <span class="hero-check w-5 h-5"></span>
                  Save Configuration
                </button>
              </div>
            </form>
          </div>
        </div>

        <!-- Provider Information -->
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title">Supported Providers</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">OpenAI</h3>
                  <p class="text-sm">gpt-4o, gpt-4-turbo, gpt-3.5-turbo</p>
                  <p class="text-xs text-base-content/60">Endpoint: https://api.openai.com/v1/chat/completions</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">Anthropic Claude</h3>
                  <p class="text-sm">claude-3-opus-20240229, claude-3-sonnet-20240229</p>
                  <p class="text-xs text-base-content/60">Endpoint: https://api.anthropic.com/v1/messages</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">Ollama (Local)</h3>
                  <p class="text-sm">llama3.2, mistral, codellama</p>
                  <p class="text-xs text-base-content/60">Endpoint: http://localhost:11434/api/chat</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">LM Studio (Local)</h3>
                  <p class="text-sm">OpenAI-compatible local models</p>
                  <p class="text-xs text-base-content/60">Endpoint: http://localhost:1234/v1/chat/completions</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">OpenRouter</h3>
                  <p class="text-sm">Access to 100+ models</p>
                  <p class="text-xs text-base-content/60">Endpoint: https://openrouter.ai/api/v1/chat/completions</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">Custom Provider</h3>
                  <p class="text-sm">Any OpenAI-compatible API</p>
                  <p class="text-xs text-base-content/60">Specify your own endpoint URL</p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Environment Variables Info -->
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Environment Variables (Production)</h2>
            <p class="text-sm text-base-content/70 mb-4">
              For production deployments, configure these environment variables instead of entering keys in the UI:
            </p>

            <div class="mockup-code">
              <pre data-prefix="$"><code>export OPENAI_API_KEY="sk-..."</code></pre>
              <pre data-prefix="$"><code>export ANTHROPIC_API_KEY="sk-ant-..."</code></pre>
              <pre data-prefix="$"><code>export OPENROUTER_API_KEY="sk-or-..."</code></pre>
            </div>

            <div class="divider"></div>

            <h2 class="card-title mt-4">About Decision Engine</h2>
            <p class="text-sm">
              Version 0.1.0 - An AI-powered architecture decision engine that helps you choose
              the right Microsoft Power Platform automation solution based on your specific requirements.
            </p>

            <div class="card-actions justify-end mt-6">
              <a
                href="https://github.com/yourusername/decision-engine"
                target="_blank"
                class="btn btn-outline"
              >
                <span class="hero-code-bracket w-5 h-5"></span>
                View on GitHub
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp provider_requires_api_key?("ollama"), do: false
  defp provider_requires_api_key?("lm_studio"), do: false
  defp provider_requires_api_key?(_), do: true

  defp get_provider_defaults("openai") do
    %{
      model: "gpt-4",
      endpoint: "https://api.openai.com/v1/chat/completions"
    }
  end

  defp get_provider_defaults("anthropic") do
    %{
      model: "claude-3-sonnet-20240229",
      endpoint: "https://api.anthropic.com/v1/messages"
    }
  end

  defp get_provider_defaults("ollama") do
    %{
      model: "llama3.2",
      endpoint: "http://localhost:11434/api/chat"
    }
  end

  defp get_provider_defaults("lm_studio") do
    %{
      model: "local-model",
      endpoint: "http://localhost:1234/v1/chat/completions"
    }
  end

  defp get_provider_defaults("openrouter") do
    %{
      model: "openai/gpt-4",
      endpoint: "https://openrouter.ai/api/v1/chat/completions"
    }
  end

  defp get_provider_defaults("custom") do
    %{
      model: "custom-model",
      endpoint: "https://your-api-endpoint.com/v1/chat/completions"
    }
  end

  defp get_provider_defaults(_) do
    %{}
  end

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> default
    end
  end

  defp parse_float(value, _default) when is_number(value), do: value
  defp parse_float(_, default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int_val, _} -> int_val
      :error -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_, default), do: default
end
