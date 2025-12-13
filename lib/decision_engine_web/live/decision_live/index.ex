# lib/decision_engine_web/live/decision_live/index.ex
defmodule DecisionEngineWeb.DecisionLive.Index do
  use DecisionEngineWeb, :live_view
  alias DecisionEngine.DescriptionGenerator
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Load available domains dynamically
    available_domains = DecisionEngine.DomainManager.list_available_domains()
    default_domain = if :power_platform in available_domains, do: :power_platform, else: List.first(available_domains)

    # Subscribe to domain changes for real-time updates
    Phoenix.PubSub.subscribe(DecisionEngine.PubSub, "domain_changes")

    # Load history using HistoryManager
    history = case DecisionEngine.HistoryManager.load_history() do
      {:ok, entries} -> Enum.take(entries, 10)  # Show last 10 entries
      {:error, _} -> []
    end

    {:ok,
     socket
     |> assign(:scenario, "")
     |> assign(:processing, false)
     |> assign(:result, nil)
     |> assign(:error, nil)
     |> assign(:provider, "ollama")
     |> assign(:api_key, "")
     |> assign(:model, "ministral-3:3b")
     |> assign(:domain, default_domain)
     |> assign(:available_domains, available_domains)
     |> assign(:streaming_enabled, false)
     |> assign(:streaming_session_id, nil)
     |> assign(:streaming_result, nil)
     |> assign(:history, history)}
  end

  @impl true
  def handle_event("validate", %{"decision" => params}, socket) do
    {:noreply, assign(socket, scenario: params["scenario"] || "")}
  end

  @impl true
  def handle_event("update_provider", %{"provider" => provider}, socket) do
    Logger.info("Provider selection changed to: #{provider}")
    default_model = case provider do
      "openai" -> "gpt-4o"
      "anthropic" -> "claude-sonnet-4-20250514"
      "ollama" -> "ministral-3:3b"
      "openrouter" -> "anthropic/claude-3.5-sonnet"
      "lm_studio" -> "ministral-3-14b-reasoning-2512"
      _ -> ""
    end

    {:noreply, socket |> assign(:provider, provider) |> assign(:model, default_model)}
  end

  @impl true
  def handle_event("update_api_key", %{"api_key" => api_key}, socket) do
    Logger.info("API key updated")
    {:noreply, assign(socket, :api_key, api_key)}
  end

  @impl true
  def handle_event("update_model", %{"model" => model}, socket) do
    Logger.info("Model updated to: #{model}")
    {:noreply, assign(socket, :model, model)}
  end

  @impl true
  def handle_event("update_domain", %{"domain" => domain_string}, socket) do
    Logger.info("Domain selection changed to: #{domain_string}")
    case DecisionEngine.Types.string_to_domain(domain_string) do
      {:ok, domain} ->
        # Verify domain is available
        if domain in socket.assigns.available_domains do
          Logger.info("Successfully updated domain to: #{domain}")
          {:noreply, assign(socket, :domain, domain)}
        else
          Logger.error("Domain not available: #{domain_string}")
          {:noreply, assign(socket, :error, "Domain not available: #{domain_string}")}
        end
      {:error, :invalid_domain} ->
        Logger.error("Invalid domain selected: #{domain_string}")
        {:noreply, assign(socket, :error, "Invalid domain selected: #{domain_string}")}
    end
  end

  @impl true
  def handle_event("update_domain", params, socket) do
    Logger.info("Domain update event received with params: #{inspect(params)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_streaming", %{"streaming" => streaming}, socket) do
    Logger.info("Streaming mode toggled: #{streaming}")
    {:noreply, assign(socket, :streaming_enabled, streaming)}
  end

  @impl true
  def handle_event("process", %{"decision" => params}, socket) do
    scenario = params["scenario"]

    if String.trim(scenario) == "" do
      {:noreply, assign(socket, error: "Please enter a scenario")}
    else
      socket =
        socket
        |> assign(:processing, true)
        |> assign(:error, nil)
        |> assign(:result, nil)
        |> assign(:streaming_result, nil)
        |> assign(:streaming_session_id, nil)

      if socket.assigns.streaming_enabled do
        # Process with streaming
        session_id = generate_session_id()

        socket = assign(socket, :streaming_session_id, session_id)

        # Send event to client to establish SSE connection first
        socket = push_event(socket, "establish_sse", %{session_id: session_id})

        # Start processing after allowing time for SSE connection
        pid = self()
        Task.start(fn ->
          # Wait for SSE connection to establish with retry logic
          wait_for_sse_connection(session_id, 5, 200)
          result = process_scenario_streaming(scenario, socket.assigns, session_id)
          send(pid, {:process_streaming_started, result})
        end)

        {:noreply, socket}
      else
        # Process traditionally
        pid = self()
        Task.start(fn ->
          result = process_scenario(scenario, socket.assigns)
          send(pid, {:process_complete, result})
        end)

        {:noreply, socket}
      end
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
  def handle_event("streaming_complete", %{"session_id" => session_id, "final_content" => final_content, "final_html" => final_html}, socket) do
    Logger.info("Streaming complete for session: #{session_id}")

    # Update the streaming result with final content
    if socket.assigns.streaming_session_id == session_id do
      streaming_result = socket.assigns.streaming_result

      if streaming_result do
        # Update justification with final content
        updated_result = put_in(streaming_result, [:justification], %{
          raw_markdown: final_content,
          rendered_html: final_html
        })

        # Save to history using HistoryManager
        save_to_history(updated_result)

        # Reload history
        history = case DecisionEngine.HistoryManager.load_history() do
          {:ok, entries} -> Enum.take(entries, 10)
          {:error, _} -> socket.assigns.history
        end

        {:noreply,
         socket
         |> assign(:processing, false)
         |> assign(:result, updated_result)
         |> assign(:streaming_result, nil)
         |> assign(:streaming_session_id, nil)
         |> assign(:history, history)}
      else
        {:noreply, assign(socket, :processing, false)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("streaming_error", %{"session_id" => session_id, "error" => error}, socket) do
    Logger.error("Streaming error for session #{session_id}: #{error}")

    if socket.assigns.streaming_session_id == session_id do
      {:noreply,
       socket
       |> assign(:processing, false)
       |> assign(:error, "Streaming error: #{error}")
       |> assign(:streaming_result, nil)
       |> assign(:streaming_session_id, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:process_complete, {:ok, result}}, socket) do
    # Save to history using HistoryManager
    save_to_history(result)

    # Reload history
    history = case DecisionEngine.HistoryManager.load_history() do
      {:ok, entries} -> Enum.take(entries, 10)
      {:error, _} -> socket.assigns.history
    end

    {:noreply,
     socket
     |> assign(:processing, false)
     |> assign(:result, result)
     |> assign(:history, history)}
  end

  @impl true
  def handle_info({:process_complete, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:processing, false)
     |> assign(:error, reason)}
  end

  @impl true
  def handle_info({:process_streaming_started, {:ok, result}}, socket) do
    Logger.info("Streaming started successfully")

    {:noreply,
     socket
     |> assign(:streaming_result, result)}
  end

  @impl true
  def handle_info({:process_streaming_started, {:error, reason}}, socket) do
    Logger.error("Failed to start streaming: #{reason}")

    {:noreply,
     socket
     |> assign(:processing, false)
     |> assign(:error, "Failed to start streaming: #{reason}")
     |> assign(:streaming_result, nil)
     |> assign(:streaming_session_id, nil)}
  end

  @impl true
  def handle_info({:domain_changed, _domain}, socket) do
    # Reload available domains when domain changes occur
    available_domains = DecisionEngine.DomainManager.list_available_domains()

    # Check if current domain is still available
    current_domain = socket.assigns.domain
    updated_domain = if current_domain in available_domains do
      current_domain
    else
      # Fall back to first available domain if current is no longer available
      List.first(available_domains) || :power_platform
    end

    {:noreply,
     socket
     |> assign(:available_domains, available_domains)
     |> assign(:domain, updated_domain)}
  end

  @impl true
  def handle_info({:domain_added, domain}, socket) do
    Logger.info("Domain added: #{domain}")
    handle_info({:domain_changed, domain}, socket)
  end

  @impl true
  def handle_info({:domain_removed, domain}, socket) do
    Logger.info("Domain removed: #{domain}")
    handle_info({:domain_changed, domain}, socket)
  end

  defp process_scenario(scenario, assigns) do
    config = build_config(assigns)
    domain = assigns.domain
    Logger.info("Processing scenario with domain: #{domain} (from assigns)")

    case DecisionEngine.process(scenario, domain, config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_scenario_streaming(scenario, assigns, session_id) do
    config = build_config(assigns)
    domain = assigns.domain
    Logger.info("Processing scenario with streaming for domain: #{domain}, session: #{session_id}")

    case DecisionEngine.process_streaming(scenario, domain, config, session_id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
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

  defp save_to_history(result) do
    # Use HistoryManager to save analysis
    DecisionEngine.HistoryManager.save_analysis(result)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <!-- Navbar -->
      <nav class="navbar bg-primary text-primary-content shadow-lg" role="navigation" aria-label="Main navigation">
        <div class="flex-1">
          <.logo_with_text
            class="btn btn-ghost text-xl"
            size="h-6 w-auto"
            text="Decision Engine"
            href="/"
            aria_label="Decision Engine home"
          />
        </div>
        <div class="flex-none gap-2" role="menubar">
          <.nav_link
            navigate="/domains"
            class="btn btn-ghost btn-sm"
            aria_label="Go to domain management"
            role="menuitem"
          >
            <span class="hero-building-office w-5 h-5" aria-hidden="true"></span>
            Domains
          </.nav_link>
          <.nav_link
            navigate="/history"
            class="btn btn-ghost btn-sm"
            aria_label="Go to decision history"
            role="menuitem"
          >
            <span class="hero-clock w-5 h-5" aria-hidden="true"></span>
            History
          </.nav_link>
          <.nav_link
            navigate="/settings"
            class="btn btn-ghost btn-sm"
            aria_label="Go to settings"
            role="menuitem"
          >
            <span class="hero-cog-6-tooth w-5 h-5" aria-hidden="true"></span>
            Settings
          </.nav_link>
        </div>
      </nav>

      <div class="container mx-auto p-6 max-w-7xl">
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Left Panel - Input -->
          <div class="lg:col-span-2 space-y-6">
            <!-- Input Card -->
            <section class="card bg-base-100 shadow-xl" aria-labelledby="input-section-title">
              <div class="card-body">
                <h2 class="card-title text-2xl mb-4" id="input-section-title">
                  <span class="hero-document-text w-7 h-7" aria-hidden="true"></span>
                  Describe Your Automation Scenario
                </h2>

                <form id="scenario-form" phx-submit="process" phx-change="validate" phx-hook="StreamingController">
                  <div class="form-control">
                    <label for="scenario-input" class="label">
                      <span class="label-text font-semibold">Scenario Description</span>
                    </label>
                    <textarea
                      id="scenario-input"
                      name="decision[scenario]"
                      class="textarea textarea-bordered h-48 text-base"
                      placeholder="Example: We need to automate an approval process when a document is uploaded in SharePoint, notify the manager in Teams, and update a record in Dataverse..."
                      phx-debounce="300"
                      aria-describedby="scenario-help"
                      aria-required="true"
                    ><%= @scenario %></textarea>
                    <label class="label">
                      <span class="label-text-alt" id="scenario-help">
                        Describe your integration or automation needs in natural language.
                        Be specific about systems, processes, and requirements.
                      </span>
                    </label>
                  </div>

                  <div class="card-actions justify-between items-center mt-4" role="group" aria-label="Form actions">
                    <div class="flex items-center gap-4">
                      <button
                        type="button"
                        phx-click="clear"
                        class="btn btn-ghost btn-sm"
                        disabled={@processing}
                        aria-label="Clear scenario text"
                      >
                        <span class="hero-x-mark w-5 h-5" aria-hidden="true"></span>
                        Clear
                      </button>

                      <!-- Streaming Toggle -->
                      <div class="form-control">
                        <label class="label cursor-pointer gap-2" for="streaming-toggle">
                          <span class="label-text text-sm">Stream response</span>
                          <input
                            id="streaming-toggle"
                            type="checkbox"
                            class="toggle toggle-primary toggle-sm"
                            phx-hook="StreamingToggle"
                            checked={@streaming_enabled}
                            aria-describedby="streaming-help"
                          />
                        </label>
                        <div id="streaming-help" class="sr-only">
                          Enable to see the AI response as it's being generated in real-time
                        </div>
                      </div>
                    </div>

                    <button
                      type="submit"
                      class="btn btn-primary"
                      disabled={@processing or String.trim(@scenario) == ""}
                      aria-describedby="submit-help"
                    >
                      <%= if @processing do %>
                        <span class="loading loading-spinner" aria-hidden="true"></span>
                        <%= if @streaming_enabled do %>
                          Streaming...
                        <% else %>
                          Processing...
                        <% end %>
                      <% else %>
                        <span class="hero-cpu-chip w-5 h-5" aria-hidden="true"></span>
                        Analyze Scenario
                      <% end %>
                    </button>
                    <div id="submit-help" class="sr-only">
                      <%= if String.trim(@scenario) == "" do %>
                        Please enter a scenario description to analyze
                      <% else %>
                        Click to analyze your scenario and get recommendations
                      <% end %>
                    </div>
                  </div>
                </form>

                <!-- Example Scenarios -->
                <div class="divider" aria-hidden="true">Quick Examples</div>
                <div class="space-y-2">
                  <h3 class="text-sm font-semibold text-base-content/70">Try these example scenarios:</h3>
                  <div class="flex flex-wrap gap-2" role="group" aria-label="Example scenarios">
                    <%= for example <- get_domain_examples(@domain) do %>
                      <button
                        phx-click="use_example"
                        phx-value-scenario={example.scenario}
                        class="btn btn-sm btn-outline"
                        aria-label={"Use example: #{example.title}"}
                        title={example.scenario}
                      >
                        <%= example.title %>
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </section>

            <!-- Results Card -->
            <%= if @result || @streaming_result do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title text-2xl">
                    <span class="hero-light-bulb w-7 h-7 text-warning"></span>
                    Recommendation
                    <%= if (@result && Map.has_key?(@result, :domain)) || (@streaming_result && Map.has_key?(@streaming_result, :domain)) do %>
                      <div class="badge badge-primary ml-2">
                        <%= format_domain_name((@result || @streaming_result).domain) %>
                      </div>
                    <% end %>
                    <%= if @streaming_result && @processing do %>
                      <div class="badge badge-info ml-2">
                        <span class="loading loading-spinner loading-xs mr-1"></span>
                        Streaming
                      </div>
                    <% end %>
                  </h2>

                  <%= if @result || (@streaming_result && @streaming_result.decision) do %>
                    <% current_result = @result || @streaming_result %>

                    <!-- Decision Badge -->
                    <div class="alert alert-success shadow-lg">
                      <span class="hero-check-circle w-6 h-6"></span>
                      <div>
                        <h3 class="font-bold"><%= current_result.decision.summary %></h3>
                        <div class="text-xs">
                          Pattern: <%= current_result.decision.pattern_id %> |
                          Confidence: <%= trunc(current_result.decision.score * 100) %>%
                          <%= if Map.has_key?(current_result, :domain) do %>
                            | Domain: <%= format_domain_name(current_result.domain) %>
                          <% end %>
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
                          <%= for {key, value} <- current_result.signals do %>
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
                        <%= if @streaming_result && @processing do %>
                          <span class="loading loading-dots loading-sm ml-2"></span>
                        <% end %>
                      </h3>

                      <%= if @streaming_result && @processing do %>
                        <!-- Streaming Content -->
                        <div
                          id={"streaming-result-#{@streaming_session_id}"}
                          phx-hook="StreamingResult"
                          data-session-id={@streaming_session_id}
                          data-streaming="true"
                          class="relative"
                        >
                          <div class="streaming-progress hidden">
                            <div class="flex items-center gap-2 mb-2">
                              <span class="loading loading-spinner loading-sm"></span>
                              <span class="text-sm text-base-content/60">Generating response...</span>
                            </div>
                          </div>
                          <div class="streaming-justification text-base-content/80 prose prose-sm max-w-none min-h-[100px] p-4 bg-base-200 rounded-lg">
                            <div class="flex items-center justify-center h-20">
                              <span class="loading loading-spinner loading-lg"></span>
                            </div>
                          </div>
                        </div>
                      <% else %>
                        <!-- Static Content -->
                        <div class="text-base-content/80 prose prose-sm max-w-none">
                          <%= raw(get_rendered_justification(current_result.justification)) %>
                        </div>
                      <% end %>
                    </div>

                    <!-- Details -->
                    <%= if Map.get(current_result.decision, :details) do %>
                      <div class="divider"></div>
                      <%= for {section, items} <- current_result.decision.details do %>
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
                  <% else %>
                    <!-- Loading state for streaming -->
                    <div class="flex items-center justify-center py-8">
                      <div class="text-center">
                        <span class="loading loading-spinner loading-lg"></span>
                        <p class="mt-2 text-base-content/60">Analyzing scenario...</p>
                      </div>
                    </div>
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
            <!-- Domain Selection Card -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <span class="hero-building-office w-6 h-6"></span>
                  Decision Domain
                </h2>

                <form phx-change="update_domain">
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Select Domain</span>
                    </label>
                    <select
                      class="select select-bordered"
                      name="domain"
                      title={get_domain_description(@domain)}
                    >
                      <%= for domain <- @available_domains do %>
                        <% description = get_domain_description(domain) %>
                        <% truncated_description = truncate_description(description) %>
                        <option
                          value={domain}
                          selected={@domain == domain}
                          title={description}
                        >
                          <%= format_domain_name(domain) %> - <%= truncated_description %>
                        </option>
                      <% end %>
                    </select>
                    <label class="label">
                      <span class="label-text-alt">Hover over options to see full descriptions</span>
                    </label>
                  </div>
                </form>

                <!-- Enhanced description display with context -->
                <div class="mt-4">
                  <div class="flex items-start gap-2">
                    <span class="hero-information-circle w-5 h-5 text-info flex-shrink-0 mt-0.5"></span>
                    <div class="flex-1">
                      <h3 class="font-medium text-sm mb-1">
                        <%= format_domain_name(@domain) %> Domain
                      </h3>
                      <p class="text-xs text-base-content/70 leading-relaxed">
                        <%= get_domain_description(@domain) %>
                      </p>
                      <%= if is_description_missing?(@domain) do %>
                        <div class="mt-2 text-xs text-warning">
                          <span class="hero-exclamation-triangle w-4 h-4 inline"></span>
                          No custom description available - using default description
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <!-- LLM Configuration Card -->
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <span class="hero-adjustments-horizontal w-6 h-6"></span>
                  LLM Configuration
                </h2>

                <form phx-change="update_provider">
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Provider</span>
                    </label>
                    <select
                      class="select select-bordered"
                      name="provider"
                    >
                      <option value="lm_studio" selected={@provider == "lm_studio"}>LM Studio (Local)</option>
                      <option value="anthropic" selected={@provider == "anthropic"}>Anthropic Claude</option>
                      <option value="openai" selected={@provider == "openai"}>OpenAI GPT</option>
                      <option value="ollama" selected={@provider == "ollama"}>Ollama (Local)</option>
                      <option value="openrouter" selected={@provider == "openrouter"}>OpenRouter</option>
                    </select>
                  </div>
                </form>

                <%= if @provider not in ["ollama", "lm_studio"] do %>
                  <form phx-change="update_api_key">
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">API Key</span>
                      </label>
                      <input
                        type="password"
                        class="input input-bordered"
                        placeholder="sk-..."
                        name="api_key"
                        value={@api_key}
                      />
                    </div>
                  </form>
                <% end %>

                <form phx-change="update_model">
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Model</span>
                    </label>
                    <input
                      type="text"
                      class="input input-bordered"
                      placeholder="Model name"
                      name="model"
                      value={@model}
                    />
                  </div>
                </form>

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
                    <%= if length(@history) > 0 do %>
                      <%= format_time(List.first(@history).timestamp) %>
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

  defp format_value(value) when is_list(value) do
    value
    |> Enum.map(&format_single_value/1)
    |> Enum.join(", ")
  end
  defp format_value(value) when is_map(value), do: inspect(value)
  defp format_value(value), do: to_string(value)

  defp format_single_value(value) when is_map(value), do: inspect(value)
  defp format_single_value(value), do: to_string(value)

  # Handle both new structured justification and legacy string justification
  defp get_rendered_justification(%{rendered_html: html}), do: html
  defp get_rendered_justification(justification) when is_binary(justification) do
    DecisionEngine.MarkdownRenderer.render_to_html!(justification)
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%b %d, %H:%M")
  end

  defp format_domain_name(domain) do
    case domain do
      :power_platform -> "Power Platform"
      :data_platform -> "Data Platform"
      :integration_platform -> "Integration Platform"
      _ -> domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp get_domain_description(domain) do
    # First try to get AI-generated description
    case DescriptionGenerator.get_cached_description(domain) do
      {:ok, ai_description} ->
        ai_description
      {:error, :not_found} ->
        # Fallback to manual description from domain config
        case DecisionEngine.DomainManager.get_domain(domain) do
          {:ok, domain_config} when domain_config.description != nil and domain_config.description != "" ->
            domain_config.description
          _ ->
            # Final fallback to hardcoded descriptions for core domains
            case domain do
              :power_platform -> "Optimized for Power Automate, Power Apps, and business user scenarios"
              :data_platform -> "Optimized for data processing, ETL, and analytics workloads"
              :integration_platform -> "Optimized for system integration and API connectivity scenarios"
              _ -> "Custom domain for specialized decision scenarios"
            end
        end
    end
  end

  defp get_domain_examples(domain) do
    case domain do
      :power_platform -> [
        %{title: "Approval Flow", scenario: "Automate approval process for SharePoint documents with Teams notifications and Dataverse updates. Built by business users."},
        %{title: "Mobile App", scenario: "Create a Power App for field workers to submit maintenance requests with photo attachments and automatic routing."},
        %{title: "Document Processing", scenario: "Automate invoice processing from email attachments with AI Builder and approval workflows in Teams."}
      ]
      :data_platform -> [
        %{title: "Data Pipeline", scenario: "Process high-volume streaming data from IoT devices to Azure Data Lake with complex transformations and mission-critical availability."},
        %{title: "Real-time Analytics", scenario: "Build real-time analytics dashboard consuming data from multiple databases with sub-second latency requirements."},
        %{title: "Data Warehouse", scenario: "Implement data warehouse solution with daily ETL from 20+ source systems and complex business rules."}
      ]
      :integration_platform -> [
        %{title: "Data Sync", scenario: "Sync customer data from Dynamics 365 to external SaaS API on record updates. High reliability required, maintained by pro developers."},
        %{title: "Legacy Integration", scenario: "Integrate legacy mainframe system with modern web APIs using message queues and transformation logic."},
        %{title: "API Gateway", scenario: "Build API gateway with authentication, rate limiting, and routing to microservices architecture."}
      ]
      _ -> [
        %{title: "Custom Scenario", scenario: "Describe your specific use case for the #{format_domain_name(domain)} domain."}
      ]
    end
  end

  defp truncate_description(description, max_length \\ 50) do
    if String.length(description) <= max_length do
      description
    else
      description
      |> String.slice(0, max_length - 3)
      |> String.trim()
      |> Kernel.<>("...")
    end
  end

  defp is_description_missing?(domain) do
    # Check if we're using a fallback description (AI-generated or manual description not available)
    case DescriptionGenerator.get_cached_description(domain) do
      {:ok, _ai_description} ->
        false  # AI description available
      {:error, :not_found} ->
        # Check if manual description exists
        case DecisionEngine.DomainManager.get_domain(domain) do
          {:ok, domain_config} when domain_config.description != nil and domain_config.description != "" ->
            false  # Manual description available
          _ ->
            true  # Using fallback description
        end
    end
  end

  # Helper function to wait for SSE connection establishment
  defp wait_for_sse_connection(session_id, retries, delay_ms) when retries > 0 do
    case DecisionEngine.StreamManager.get_stream_status(session_id) do
      {:ok, _status} ->
        Logger.info("SSE connection confirmed for session #{session_id}")
        :ok
      {:error, :not_found} ->
        Logger.debug("Waiting for SSE connection for session #{session_id}, retries left: #{retries}")
        Process.sleep(delay_ms)
        wait_for_sse_connection(session_id, retries - 1, delay_ms)
    end
  end

  defp wait_for_sse_connection(session_id, 0, _delay_ms) do
    Logger.warning("SSE connection not established for session #{session_id} after retries")
    :timeout
  end
end
