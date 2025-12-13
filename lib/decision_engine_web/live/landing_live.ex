# lib/decision_engine_web/live/landing_live.ex
defmodule DecisionEngineWeb.LandingLive do
  use DecisionEngineWeb, :live_view
  import DecisionEngineWeb.Components.Logo
  import DecisionEngineWeb.Components.Icons

  @impl true
  def mount(_params, _session, socket) do
    # Get some basic stats for the landing page
    stats = get_system_stats()

    {:ok, assign(socket, :stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200" phx-hook="IconLoader" id="landing-page">
      <!-- Hero Section -->

<section class="bg-gradient-to-br from-primary/10 via-base-200 to-secondary/10">
  <div class="max-w-5xl mx-auto min-h-[60vh] flex flex-col items-center justify-center px-6 py-16 text-center">
    <!-- Logo -->
    <img
      src={~p"/images/logo.png"}
      alt="Decision Engine logo"
      class="w-32 h-32 mb-4 mx-auto rounded-2xl shadow-lg"
    />

    <!-- Title -->
    <h1 class="text-4xl md:text-5xl font-bold tracking-tight mb-3">
      Decision Engine
    </h1>

    <!-- Subtitle -->
    <p class="text-base md:text-lg text-base-content/70 max-w-2xl mb-10 leading-relaxed">
      AI-powered decision automation platform that transforms business scenarios
      into intelligent recommendations using configurable rule engines and LLM analysis.
    </p>

    <!-- Feature Cards -->
    <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-10 w-full">
      <!-- Card 1 -->
      <div class="card bg-base-100 shadow-md">
        <div class="card-body text-center">
          <h3 class="font-semibold text-lg mb-2">AI Analysis</h3>
          <p class="text-sm text-base-content/70">
            Advanced LLM integration extracts signals from natural language scenarios
            and generates intelligent justifications.
          </p>
        </div>
      </div>

      <!-- Card 2 -->
      <div class="card bg-base-100 shadow-md">
        <div class="card-body text-center">
          <h3 class="font-semibold text-lg mb-2">Domain-Driven</h3>
          <p class="text-sm text-base-content/70">
            Configurable decision domains for business contexts like Power Platform,
            Data Platform, and Integration scenarios.
          </p>
        </div>
      </div>

      <!-- Card 3 -->
      <div class="card bg-base-100 shadow-md">
        <div class="card-body text-center">
          <h3 class="font-semibold text-lg mb-2">PDF Integration</h3>
          <p class="text-sm text-base-content/70">
            Upload reference documents and automatically generate domain configurations
            from existing business rules and processes.
          </p>
        </div>
      </div>
    </div>

    <!-- CTA Buttons -->
    <div class="flex flex-col sm:flex-row gap-4 mb-10">
      <.nav_link navigate="/analyze" class="btn btn-primary btn-wide">
        Start Analyzing
      </.nav_link>

      <.nav_link navigate="/domains" class="btn btn-outline btn-wide btn-secondary">
        Manage Domains
      </.nav_link>
    </div>

    <!-- Stats -->
    <div class="stats shadow bg-base-100">
      <div class="stat">
        <div class="stat-title">Configured Domains</div>
        <div class="stat-value text-primary"><%= @stats.total_domains %></div>
      </div>

      <div class="stat">
        <div class="stat-title">Decisions Made</div>
        <div class="stat-value text-secondary"><%= @stats.total_decisions %></div>
      </div>
    </div>
  </div>
</section>

      <!-- How It Works Section -->
      <section class="py-20 bg-base-100">
        <div class="container mx-auto px-6 max-w-6xl">
          <div class="text-center mb-16">
            <h2 class="text-4xl font-bold mb-4">How It Works</h2>
            <p class="text-xl text-base-content/70 max-w-2xl mx-auto">
              Transform your business scenarios into actionable decisions through our intelligent analysis pipeline.
            </p>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
            <!-- Step 1 -->
            <div class="text-center">
              <div class="step-circle bg-primary/10">
                <span class="text-primary">1</span>
              </div>
              <h3 class="text-xl font-semibold mb-2">Describe Scenario</h3>
              <p class="text-base-content/70">
                Input your business scenario in natural language. Describe your automation needs,
                integration requirements, or decision criteria.
              </p>
            </div>

            <!-- Step 2 -->
            <div class="text-center">
              <div class="step-circle bg-secondary/10">
                <span class="text-secondary">2</span>
              </div>
              <h3 class="text-xl font-semibold mb-2">AI Extraction</h3>
              <p class="text-base-content/70">
                Our LLM analyzes your scenario and extracts key signals like complexity,
                user types, systems involved, and business requirements.
              </p>
            </div>

            <!-- Step 3 -->
            <div class="text-center">
              <div class="step-circle bg-accent/10">
                <span class="text-accent">3</span>
              </div>
              <h3 class="text-xl font-semibold mb-2">Rule Evaluation</h3>
              <p class="text-base-content/70">
                Domain-specific rule engines evaluate the extracted signals against
                configured patterns to determine the best approach.
              </p>
            </div>

            <!-- Step 4 -->
            <div class="text-center">
              <div class="step-circle bg-info/10">
                <span class="text-info">4</span>
              </div>
              <h3 class="text-xl font-semibold mb-2">Get Recommendation</h3>
              <p class="text-base-content/70">
                Receive detailed recommendations with confidence scores,
                implementation guidance, and AI-generated justifications.
              </p>
            </div>
          </div>
        </div>
      </section>

      <!-- Features Section -->
      <section class="py-20 bg-base-200">
        <div class="container mx-auto px-6 max-w-6xl">
          <div class="text-center mb-16">
            <h2 class="text-4xl font-bold mb-4">Powerful Features</h2>
            <p class="text-xl text-base-content/70">
              Everything you need to make intelligent, data-driven decisions.
            </p>
          </div>

          <div class="feature-grid grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
            <!-- Feature Cards -->
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <.icon name="adjustments-horizontal" class="w-8 h-8 text-primary mb-2" />
                <h3 class="card-title text-lg">Configurable Domains</h3>
                <p class="text-sm text-base-content/70">
                  Create custom decision domains tailored to your specific business contexts
                  and requirements.
                </p>
              </div>
            </div>

            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <.icon name="clock" class="w-8 h-8 text-secondary mb-2" />
                <h3 class="card-title text-lg">Decision History</h3>
                <p class="text-sm text-base-content/70">
                  Track all decisions with full context, export capabilities,
                  and searchable history for audit trails.
                </p>
              </div>
            </div>

            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <.icon name="bolt" class="w-8 h-8 text-accent mb-2" />
                <h3 class="card-title text-lg">Real-time Streaming</h3>
                <p class="text-sm text-base-content/70">
                  Watch AI analysis unfold in real-time with streaming responses
                  and live status indicators.
                </p>
              </div>
            </div>

            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <.icon name="document-arrow-up" class="w-8 h-8 text-info mb-2" />
                <h3 class="card-title text-lg">PDF Document Analysis</h3>
                <p class="text-sm text-base-content/70">
                  Upload existing business documents and automatically generate
                  domain configurations from your processes.
                </p>
              </div>
            </div>

            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <.icon name="cog-6-tooth" class="w-8 h-8 text-warning mb-2" />
                <h3 class="card-title text-lg">LLM Integration</h3>
                <p class="text-sm text-base-content/70">
                  Support for multiple LLM providers including OpenAI, Anthropic,
                  Ollama, and local LM Studio instances.
                </p>
              </div>
            </div>

            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <.icon name="chart-bar" class="w-8 h-8 text-success mb-2" />
                <h3 class="card-title text-lg">Analytics & Export</h3>
                <p class="text-sm text-base-content/70">
                  Export decision data in multiple formats and analyze patterns
                  in your decision-making processes.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      <!-- Navigation Section -->
      <section class="py-20 bg-base-100">
        <div class="container mx-auto px-6 max-w-4xl">
          <div class="text-center mb-12">
            <h2 class="text-4xl font-bold mb-4">Get Started</h2>
            <p class="text-xl text-base-content/70">
              Explore the platform and start making intelligent decisions today.
            </p>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
            <!-- Navigation Cards -->
            <a
              href="/analyze"
              class="card bg-primary/5 hover:bg-primary/10 transition-colors border border-primary/20 hover:border-primary/40"
            >
              <div class="card-body text-center">
                <.icon name="cpu-chip" class="w-12 h-12 text-primary mx-auto mb-2" />
                <h3 class="card-title justify-center text-lg">Analyze</h3>
                <p class="text-sm text-base-content/70">
                  Start analyzing your business scenarios and get AI-powered recommendations.
                </p>
              </div>
            </a>

            <a
              href="/domains"
              class="card bg-secondary/5 hover:bg-secondary/10 transition-colors border border-secondary/20 hover:border-secondary/40"
            >
              <div class="card-body text-center">
                <.icon name="building-office" class="w-12 h-12 text-secondary mx-auto mb-2" />
                <h3 class="card-title justify-center text-lg">Domains</h3>
                <p class="text-sm text-base-content/70">
                  Configure decision domains and upload PDF documents for analysis.
                </p>
              </div>
            </a>

            <a
              href="/history"
              class="card bg-accent/5 hover:bg-accent/10 transition-colors border border-accent/20 hover:border-accent/40"
            >
              <div class="card-body text-center">
                <.icon name="clock" class="w-12 h-12 text-accent mx-auto mb-2" />
                <h3 class="card-title justify-center text-lg">History</h3>
                <p class="text-sm text-base-content/70">
                  Review past decisions, search history, and export data for analysis.
                </p>
              </div>
            </a>

            <a
              href="/settings"
              class="card bg-info/5 hover:bg-info/10 transition-colors border border-info/20 hover:border-info/40"
            >
              <div class="card-body text-center">
                <.icon name="cog-6-tooth" class="w-12 h-12 text-info mx-auto mb-2" />
                <h3 class="card-title justify-center text-lg">Settings</h3>
                <p class="text-sm text-base-content/70">
                  Configure LLM providers, API keys, and system preferences.
                </p>
              </div>
            </a>
          </div>
        </div>
      </section>

      <!-- Footer -->
      <footer class="footer footer-center p-10 bg-base-300 text-base-content">
        <div>
          <.logo class="w-12 h-12" />
          <p class="font-bold text-lg">Decision Engine</p>
          <p class="text-base-content/70">AI-powered decision automation platform</p>
        </div>
      </footer>
    </div>
    """
  end

  # Private helper functions

  defp get_system_stats do
    # Get domain count
    total_domains =
      case DecisionEngine.DomainManager.list_domains() do
        {:ok, domains} -> length(domains)
        {:error, _} -> 0
      end

    # Get decision history stats
    {total_decisions, last_decision} =
      case DecisionEngine.HistoryManager.load_history() do
        {:ok, [first_entry | _] = history} ->
          {length(history), first_entry.timestamp}

        _ ->
          {0, nil}
      end

    %{
      total_domains: total_domains,
      total_decisions: total_decisions,
      last_decision: last_decision
    }
  end

  # defp format_time(datetime) do
  #   Calendar.strftime(datetime, "%b %d, %H:%M")
  # end
end
