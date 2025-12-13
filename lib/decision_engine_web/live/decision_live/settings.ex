# lib/decision_engine_web/live/decision_live/settings.ex
defmodule DecisionEngineWeb.DecisionLive.Settings do
  use DecisionEngineWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:saved, false)}
  end

  @impl true
  def handle_event("save_settings", _params, socket) do
    # In production, save to database or persistent storage
    # For now, just show a success message
    {:noreply, assign(socket, saved: true)}
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
        </div>
      </div>

      <div class="container mx-auto p-6 max-w-4xl">
        <h1 class="text-3xl font-bold mb-6">
          <span class="hero-cog-6-tooth w-8 h-8 inline"></span>
          Settings
        </h1>

        <%= if @saved do %>
          <div class="alert alert-success shadow-lg mb-6">
            <span class="hero-check-circle w-6 h-6"></span>
            <span>Settings saved successfully!</span>
          </div>
        <% end %>

        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title">Environment Variables</h2>
            <p class="text-sm text-base-content/70 mb-4">
              For production use, configure these environment variables instead of entering keys in the UI:
            </p>

            <div class="mockup-code">
              <pre data-prefix="$"><code>export OPENAI_API_KEY="sk-..."</code></pre>
              <pre data-prefix="$"><code>export ANTHROPIC_API_KEY="sk-ant-..."</code></pre>
              <pre data-prefix="$"><code>export OPENROUTER_API_KEY="sk-or-..."</code></pre>
            </div>

            <div class="divider"></div>

            <h2 class="card-title mt-4">Supported Providers</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">Anthropic Claude</h3>
                  <p class="text-sm">claude-sonnet-4-20250514, claude-opus-4-20250514</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">OpenAI</h3>
                  <p class="text-sm">gpt-4o, gpt-4-turbo, gpt-3.5-turbo</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">Ollama (Local)</h3>
                  <p class="text-sm">llama3.2, mistral, codellama</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">LM Studio (Local)</h3>
                  <p class="text-sm">OpenAI-compatible at http://localhost:1234</p>
                </div>
              </div>

              <div class="card bg-base-200">
                <div class="card-body">
                  <h3 class="card-title text-base">OpenRouter</h3>
                  <p class="text-sm">Access to 100+ models</p>
                </div>
              </div>
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
end
