# lib/decision_engine_web/live/decision_live/index.ex
defmodule DecisionEngineWeb.DecisionLive.Index do
  use DecisionEngineWeb, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:scenario, "")
     |> assign(:processing, false)
     |> assign(:result, nil)
     |> assign(:error, nil)
     |> assign(:provider, "ollama")
     |> assign(:api_key, "")
     |> assign(:model, "ministral-3:3b")
     |> assign(:history, load_history())}
  end

  @impl true
  def handle_event("validate", %{"decision" => params}, socket) do
    {:noreply, assign(socket, scenario: params["scenario"] || "")}
  end

  @impl true
  def handle_event("update_provider", %{"provider" => provider}, socket) do
    default_model = case provider do
      "openai" -> "gpt-4o"
      "anthropic" -> "claude-sonnet-4-20250514"
      "ollama" -> "ministral-3:3b"
      "openrouter" -> "anthropic/claude-3.5-sonnet"
      "lm_studio" -> "local-model"
      _ -> ""
    end

    {:noreply, socket |> assign(:provider, provider) |> assign(:model, default_model)}
  end

  @impl true
  def handle_event("update_api_key", %{"api_key" => api_key}, socket) do
    {:noreply, assign(socket, :api_key, api_key)}
  end

  @impl true
  def handle_event("update_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model, model)}
  end

  @impl true
  def handle_event("process", %{"decision" => params}, socket) do
    scenario = params["scenario"]

    if String.trim(scenario) == "" do
      {:noreply, assign(socket, error: "Please enter a scenario")}
    else
      socket = assign(socket, processing: true, error: nil, result: nil)

      # Process asynchronously
      pid = self()
      Task.start(fn ->
        result = process_scenario(scenario, socket.assigns)
        send(pid, {:process_complete, result})
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(:scenario, "")
     |> assign(:result, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("use_example", %{"scenario" => scenario}, socket) do
    {:noreply, assign(socket, scenario: scenario)}
  end

  @impl true
  def handle_info({:process_complete, {:ok, result}}, socket) do
    # Save to history
    save_to_history(result)

    {:noreply,
     socket
     |> assign(:processing, false)
     |> assign(:result, result)
     |> assign(:history, load_history())}
  end

  @impl true
  def handle_info({:process_complete, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:processing, false)
     |> assign(:error, reason)}
  end

  defp process_scenario(scenario, assigns) do
    config = build_config(assigns)

    case DecisionEngine.process(scenario, config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_config(assigns) do
    case assigns.provider do
      "openai" ->
        DecisionEngine.ConfigBuilder.openai(assigns.api_key, model: assigns.model)

      "anthropic" ->
        DecisionEngine.ConfigBuilder.anthropic(assigns.api_key, model: assigns.model)

      "ollama" ->
        DecisionEngine.ConfigBuilder.ollama(assigns.model)

      "openrouter" ->
        DecisionEngine.ConfigBuilder.openrouter(assigns.api_key, model: assigns.model)

      "lm_studio" ->
        DecisionEngine.ConfigBuilder.lm_studio(assigns.model)
    end
  end

  defp load_history do
    # In production, use a database
    # For now, we'll use process dictionary or ETS
    case :ets.whereis(:decision_history) do
      :undefined ->
        :ets.new(:decision_history, [:named_table, :public, :ordered_set])
        []

      _table ->
        :ets.tab2list(:decision_history)
        |> Enum.sort_by(fn {timestamp, _} -> timestamp end, :desc)
        |> Enum.take(10)
        |> Enum.map(fn {_, result} -> result end)
    end
  end

  defp save_to_history(result) do
    case :ets.whereis(:decision_history) do
      :undefined ->
        :ets.new(:decision_history, [:named_table, :public, :ordered_set])
      _ -> :ok
    end

    timestamp = :os.system_time(:millisecond)
    :ets.insert(:decision_history, {timestamp, result})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <!-- Navbar -->
      <div class="navbar bg-primary text-primary-content shadow-lg">
        <div class="flex-1">
          <a href="/" class="btn btn-ghost text-xl">
            <span class="hero-sparkles w-6 h-6 mr-2"></span>
            Decision Engine
          </a>
        </div>
        <div class="flex-none gap-2">
          <.nav_link navigate="/history" class="btn btn-ghost btn-sm">
            <span class="hero-clock w-5 h-5"></span>
            History
          </.nav_link>
          <.nav_link navigate="/settings" class="btn btn-ghost btn-sm">
            <span class="hero-cog-6-tooth w-5 h-5"></span>
            Settings
          </.nav_link>
        </div>
      </div>

      <div class="container mx-auto p-6 max-w-7xl">
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Left Panel - Input -->
          <div class="lg:col-span-2 space-y-6">
            <!-- Input Card -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-2xl mb-4">
                  <span class="hero-document-text w-7 h-7"></span>
                  Describe Your Automation Scenario
                </h2>

                <form phx-submit="process" phx-change="validate">
                  <div class="form-control">
                    <textarea
                      name="decision[scenario]"
                      class="textarea textarea-bordered h-48 text-base"
                      placeholder="Example: We need to automate an approval process when a document is uploaded in SharePoint, notify the manager in Teams, and update a record in Dataverse..."
                      phx-debounce="300"
                    ><%= @scenario %></textarea>
                    <label class="label">
                      <span class="label-text-alt">Describe your integration or automation needs in natural language</span>
                    </label>
                  </div>

                  <div class="card-actions justify-between items-center mt-4">
                    <button
                      type="button"
                      phx-click="clear"
                      class="btn btn-ghost btn-sm"
                      disabled={@processing}
                    >
                      <span class="hero-x-mark w-5 h-5"></span>
                      Clear
                    </button>

                    <button
                      type="submit"
                      class="btn btn-primary"
                      disabled={@processing or String.trim(@scenario) == ""}
                    >
                      <%= if @processing do %>
                        <span class="loading loading-spinner"></span>
                        Processing...
                      <% else %>
                        <span class="hero-cpu-chip w-5 h-5"></span>
                        Analyze Scenario
                      <% end %>
                    </button>
                  </div>
                </form>

                <!-- Example Scenarios -->
                <div class="divider">Quick Examples</div>
                <div class="flex flex-wrap gap-2">
                  <button
                    phx-click="use_example"
                    phx-value-scenario="Automate approval process for SharePoint documents with Teams notifications and Dataverse updates. Built by business users."
                    class="btn btn-sm btn-outline"
                  >
                    Approval Flow
                  </button>
                  <button
                    phx-click="use_example"
                    phx-value-scenario="Sync customer data from Dynamics 365 to external SaaS API on record updates. High reliability required, maintained by pro developers."
                    class="btn btn-sm btn-outline"
                  >
                    Data Sync
                  </button>
                  <button
                    phx-click="use_example"
                    phx-value-scenario="Process high-volume streaming data from IoT devices to Azure Data Lake with complex transformations and mission-critical availability."
                    class="btn btn-sm btn-outline"
                  >
                    Data Pipeline
                  </button>
                </div>
              </div>
            </div>

            <!-- Results Card -->
            <%= if @result do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title text-2xl">
                    <span class="hero-light-bulb w-7 h-7 text-warning"></span>
                    Recommendation
                  </h2>

                  <!-- Decision Badge -->
                  <div class="alert alert-success shadow-lg">
                    <span class="hero-check-circle w-6 h-6"></span>
                    <div>
                      <h3 class="font-bold"><%= @result.decision.summary %></h3>
                      <div class="text-xs">
                        Pattern: <%= @result.decision.pattern_id %> |
                        Confidence: <%= trunc(@result.decision.score * 100) %>%
                      </div>
                    </div>
                  </div>

                  <!-- Extracted Signals -->
                  <div class="collapse collapse-arrow bg-base-200 mt-4">
                    <input type="checkbox" />
                    <div class="collapse-title font-medium">
                      <span class="hero-signal w-5 h-5 inline"></span>
                      Extracted Signals
                    </div>
                    <div class="collapse-content">
                      <div class="grid grid-cols-2 gap-2 mt-2">
                        <%= for {key, value} <- @result.signals do %>
                          <div class="badge badge-outline">
                            <%= key %>: <%= format_value(value) %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <!-- Justification -->
                  <div class="mt-4">
                    <h3 class="font-bold text-lg mb-2">
                      <span class="hero-document-text w-5 h-5 inline"></span>
                      Why This Recommendation?
                    </h3>
                    <p class="text-base-content/80 whitespace-pre-line"><%= @result.justification %></p>
                  </div>

                  <!-- Details -->
                  <%= if Map.get(@result.decision, :details) do %>
                    <div class="divider"></div>
                    <%= for {section, items} <- @result.decision.details do %>
                      <%= if items && length(items) > 0 do %>
                        <div class="mb-4">
                          <h4 class="font-semibold mb-2 capitalize">
                            <%= section |> to_string() |> String.replace("_", " ") %>
                          </h4>
                          <ul class="list-disc list-inside space-y-1">
                            <%= for item <- items do %>
                              <li class="text-sm"><%= item %></li>
                            <% end %>
                          </ul>
                        </div>
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% end %>

            <!-- Error Display -->
            <%= if @error do %>
              <div class="alert alert-error shadow-lg">
                <span class="hero-exclamation-triangle w-6 h-6"></span>
                <span><%= @error %></span>
              </div>
            <% end %>
          </div>

          <!-- Right Panel - Configuration -->
          <div class="space-y-6">
            <!-- LLM Configuration Card -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <span class="hero-adjustments-horizontal w-6 h-6"></span>
                  LLM Configuration
                </h2>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Provider</span>
                  </label>
                  <select
                    class="select select-bordered"
                    phx-change="update_provider"
                    name="provider"
                  >
                    <option value="lm_studio" selected={@provider == "lm_studio"}>LM Studio (Local)</option>
                    <option value="anthropic" selected={@provider == "anthropic"}>Anthropic Claude</option>
                    <option value="openai" selected={@provider == "openai"}>OpenAI GPT</option>
                    <option value="ollama" selected={@provider == "ollama"}>Ollama (Local)</option>
                    <option value="openrouter" selected={@provider == "openrouter"}>OpenRouter</option>
                  </select>
                </div>

                <%= if @provider not in ["ollama", "lm_studio"] do %>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">API Key</span>
                    </label>
                    <input
                      type="password"
                      class="input input-bordered"
                      placeholder="sk-..."
                      phx-change="update_api_key"
                      name="api_key"
                      value={@api_key}
                    />
                  </div>
                <% end %>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Model</span>
                  </label>
                  <input
                    type="text"
                    class="input input-bordered"
                    placeholder="Model name"
                    phx-change="update_model"
                    name="model"
                    value={@model}
                  />
                </div>

                <div class="alert alert-info mt-4">
                  <span class="hero-information-circle w-5 h-5"></span>
                  <span class="text-xs">
                    API keys are not stored. For production, use environment variables.
                  </span>
                </div>
              </div>
            </div>

            <!-- Info Card -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <span class="hero-information-circle w-6 h-6"></span>
                  How It Works
                </h2>
                <div class="text-sm space-y-2">
                  <div class="flex items-start gap-2">
                    <span class="badge badge-primary badge-sm">1</span>
                    <p>LLM extracts signals from your scenario</p>
                  </div>
                  <div class="flex items-start gap-2">
                    <span class="badge badge-primary badge-sm">2</span>
                    <p>Rule engine evaluates decision patterns</p>
                  </div>
                  <div class="flex items-start gap-2">
                    <span class="badge badge-primary badge-sm">3</span>
                    <p>LLM generates justification</p>
                  </div>
                </div>
              </div>
            </div>

            <!-- Stats Card -->
            <%= if length(@history) > 0 do %>
              <div class="stats stats-vertical shadow">
                <div class="stat">
                  <div class="stat-title">Total Decisions</div>
                  <div class="stat-value text-primary"><%= length(@history) %></div>
                </div>
                <div class="stat">
                  <div class="stat-title">Last Decision</div>
                  <div class="stat-value text-sm">
                    <%= if hd(@history) do %>
                      <%= format_time(hd(@history).timestamp) %>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(value), do: to_string(value)

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%b %d, %H:%M")
  end
end
