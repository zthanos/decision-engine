defmodule DecisionEngineWeb.DomainManagementLive do
  use DecisionEngineWeb, :live_view
  alias DecisionEngine.DomainManager
  alias DecisionEngine.DescriptionGenerator
  import DecisionEngineWeb.Components.Icons
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, domains} = DomainManager.list_domains()

    socket =
      socket
      |> assign(:domains, domains)
      |> assign(:selected_domain, nil)
      |> assign(:form_mode, :list)
      |> assign(:form_data, %{})
      |> assign(:errors, [])
      |> assign(:show_delete_modal, false)
      |> assign(:domain_to_delete, nil)
      |> assign(:expanded_domain, nil)
      |> assign(:generating_description, nil)
      |> assign(:description_error, nil)
      |> assign(:pdf_upload_mode, false)
      |> assign(:pdf_processing, false)
      |> assign(:pdf_error, nil)
      |> allow_upload(:pdf_file,
          accept: ~w(.pdf),
          max_entries: 1,
          max_file_size: 10_000_000)  # 10MB limit

    {:ok, socket}
  end

  @impl true
  def handle_event("new_domain", _params, socket) do
    form_data = %{
      name: "",
      display_name: "",
      description: "",
      signals_fields: [""],
      patterns: [default_pattern()],
      schema_module: ""
    }

    socket =
      socket
      |> assign(:form_mode, :new)
      |> assign(:form_data, form_data)
      |> assign(:errors, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_domain", %{"domain" => domain_name}, socket) do
    domain_atom = String.to_atom(domain_name)

    case DomainManager.get_domain(domain_atom) do
      {:ok, domain_config} ->
        socket =
          socket
          |> assign(:form_mode, :edit)
          |> assign(:selected_domain, domain_atom)
          |> assign(:form_data, domain_config)
          |> assign(:errors, [])

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load domain configuration")}
    end
  end

  @impl true
  def handle_event("show_delete_modal", %{"domain" => domain_name}, socket) do
    socket =
      socket
      |> assign(:show_delete_modal, true)
      |> assign(:domain_to_delete, domain_name)

    {:noreply, socket}
  end

  @impl true
  def handle_event("hide_delete_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_delete_modal, false)
      |> assign(:domain_to_delete, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_delete_domain", _params, socket) do
    domain_name = socket.assigns.domain_to_delete
    domain_atom = String.to_atom(domain_name)

    case DomainManager.delete_domain(domain_atom) do
      :ok ->
        {:ok, domains} = DomainManager.list_domains()

        socket =
          socket
          |> assign(:domains, domains)
          |> assign(:form_mode, :list)
          |> assign(:show_delete_modal, false)
          |> assign(:domain_to_delete, nil)
          |> put_flash(:info, "Domain deleted successfully")

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          socket
          |> assign(:show_delete_modal, false)
          |> assign(:domain_to_delete, nil)
          |> put_flash(:error, "Failed to delete domain")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_domain", %{"domain" => domain_params}, socket) do
    domain_config = %{
      name: domain_params["name"],
      display_name: domain_params["display_name"],
      description: domain_params["description"],
      signals_fields: parse_signals_fields(domain_params["signals_fields"]),
      patterns: parse_patterns(domain_params["patterns"]),
      schema_module: domain_params["schema_module"]
    }

    case DomainManager.validate_domain_config(domain_config) do
      :ok ->
        result = case socket.assigns.form_mode do
          :new -> DomainManager.create_domain(domain_config)
          :edit -> DomainManager.update_domain(socket.assigns.selected_domain, domain_config)
        end

        case result do
          {:ok, _} ->
            {:ok, domains} = DomainManager.list_domains()

            socket =
              socket
              |> assign(:domains, domains)
              |> assign(:form_mode, :list)
              |> assign(:errors, [])
              |> put_flash(:info, "Domain saved successfully")

            {:noreply, socket}

          {:error, :domain_already_exists} ->
            {:noreply, assign(socket, :errors, ["Domain name already exists"])}

          {:error, _reason} ->
            {:noreply, assign(socket, :errors, ["Failed to save domain configuration"])}
        end

      {:error, errors} ->
        {:noreply, assign(socket, :errors, errors)}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    socket =
      socket
      |> assign(:form_mode, :list)
      |> assign(:errors, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_signal_field", _params, socket) do
    form_data = socket.assigns.form_data
    updated_fields = form_data.signals_fields ++ [""]
    updated_form_data = %{form_data | signals_fields: updated_fields}

    {:noreply, assign(socket, :form_data, updated_form_data)}
  end

  @impl true
  def handle_event("remove_signal_field", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    form_data = socket.assigns.form_data
    updated_fields = List.delete_at(form_data.signals_fields, index)
    updated_form_data = %{form_data | signals_fields: updated_fields}

    {:noreply, assign(socket, :form_data, updated_form_data)}
  end

  @impl true
  def handle_event("update_signal_field", %{"index" => index_str, "value" => value}, socket) do
    index = String.to_integer(index_str)
    form_data = socket.assigns.form_data
    updated_fields = List.replace_at(form_data.signals_fields, index, value)
    updated_form_data = %{form_data | signals_fields: updated_fields}

    {:noreply, assign(socket, :form_data, updated_form_data)}
  end

  @impl true
  def handle_event("add_pattern", _params, socket) do
    form_data = socket.assigns.form_data
    updated_patterns = form_data.patterns ++ [default_pattern()]
    updated_form_data = %{form_data | patterns: updated_patterns}

    {:noreply, assign(socket, :form_data, updated_form_data)}
  end

  @impl true
  def handle_event("remove_pattern", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    form_data = socket.assigns.form_data
    updated_patterns = List.delete_at(form_data.patterns, index)
    updated_form_data = %{form_data | patterns: updated_patterns}

    {:noreply, assign(socket, :form_data, updated_form_data)}
  end

  @impl true
  def handle_event("update_pattern_field", %{"index" => index_str, "field" => field, "value" => value}, socket) do
    index = String.to_integer(index_str)
    form_data = socket.assigns.form_data

    updated_patterns =
      form_data.patterns
      |> List.update_at(index, fn pattern ->
        case field do
          "score" ->
            case Float.parse(value) do
              {float_val, _} -> Map.put(pattern, field, float_val)
              :error -> pattern
            end
          _ ->
            Map.put(pattern, field, value)
        end
      end)

    updated_form_data = %{form_data | patterns: updated_patterns}

    {:noreply, assign(socket, :form_data, updated_form_data)}
  end

  @impl true
  def handle_event("toggle_domain_details", %{"domain" => domain_name}, socket) do
    current_expanded = socket.assigns[:expanded_domain]
    domain_atom = String.to_atom(domain_name)

    new_expanded = if current_expanded == domain_atom, do: nil, else: domain_atom

    {:noreply, assign(socket, :expanded_domain, new_expanded)}
  end

  @impl true
  def handle_event("clear_errors", _params, socket) do
    {:noreply, assign(socket, :errors, [])}
  end

  @impl true
  def handle_event("generate_description", %{"domain" => domain_name}, socket) do
    domain_atom = String.to_atom(domain_name)

    # Set generating state
    socket =
      socket
      |> assign(:generating_description, domain_atom)
      |> assign(:description_error, nil)

    # Start async description generation
    pid = self()
    Task.start(fn ->
      case DescriptionGenerator.generate_description(domain_atom) do
        {:ok, description} ->
          send(pid, {:description_generated, domain_atom, description})
        {:error, reason} ->
          send(pid, {:description_generation_failed, domain_atom, reason})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_description_error", _params, socket) do
    socket = assign(socket, :description_error, nil)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_pdf_upload", _params, socket) do
    socket =
      socket
      |> assign(:pdf_upload_mode, !socket.assigns.pdf_upload_mode)
      |> assign(:pdf_error, nil)
    {:noreply, socket}
  end

  @impl true
  def handle_event("process_pdf", %{"domain_name" => domain_name}, socket) do
    case uploaded_entries(socket, :pdf_file) do
      [entry] ->
        # Set processing state
        socket =
          socket
          |> assign(:pdf_processing, true)
          |> assign(:pdf_error, nil)

        # Start async PDF processing
        pid = self()
        Task.start(fn ->
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            case DecisionEngine.PDFProcessor.process_pdf_for_domain(path, domain_name) do
              {:ok, domain_config} ->
                send(pid, {:pdf_processed, domain_config})
                {:ok, :processed}
              {:error, reason} ->
                send(pid, {:pdf_processing_failed, reason})
                {:ok, :failed}
            end
          end)
        end)

        {:noreply, socket}

      [] ->
        socket = assign(socket, :pdf_error, "Please select a PDF file to upload")
        {:noreply, socket}

      _multiple ->
        socket = assign(socket, :pdf_error, "Please select only one PDF file")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_pdf", _params, socket) do
    # Handle file validation during upload
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_pdf_upload", _params, socket) do
    socket =
      socket
      |> assign(:pdf_upload_mode, false)
      |> assign(:pdf_processing, false)
      |> assign(:pdf_error, nil)
    {:noreply, socket}
  end

  defp default_pattern do
    %{
      "id" => "",
      "outcome" => "",
      "score" => 0.5,
      "summary" => "",
      "use_when" => [],
      "avoid_when" => [],
      "typical_use_cases" => []
    }
  end

  defp parse_signals_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_signals_fields(fields_string) when is_binary(fields_string) do
    fields_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_patterns(patterns) when is_list(patterns) do
    patterns
  end

  defp parse_patterns(_), do: []

  @impl true
  def handle_info({:description_generated, domain_atom, _description}, socket) do
    Logger.info("Description generated for domain: #{domain_atom}")

    # Reload domains to get updated configuration
    {:ok, domains} = DomainManager.list_domains()

    socket =
      socket
      |> assign(:domains, domains)
      |> assign(:generating_description, nil)
      |> put_flash(:info, "Description generated successfully for #{format_domain_name(Atom.to_string(domain_atom))}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:description_generation_failed, domain_atom, reason}, socket) do
    Logger.error("Description generation failed for domain #{domain_atom}: #{inspect(reason)}")

    error_message = case reason do
      :no_api_key_configured -> "LLM API key not configured. Please set OPENAI_API_KEY environment variable."
      {:llm_call_failed, _} -> "Failed to connect to LLM service. Please check your internet connection and API configuration."
      _ -> "Failed to generate description. Please try again or enter a description manually."
    end

    socket =
      socket
      |> assign(:generating_description, nil)
      |> assign(:description_error, {domain_atom, error_message})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pdf_processed, domain_config}, socket) do
    Logger.info("PDF processed successfully, generated domain: #{domain_config.name}")

    # Switch to edit mode with the generated configuration
    socket =
      socket
      |> assign(:form_mode, :new)
      |> assign(:form_data, domain_config)
      |> assign(:pdf_processing, false)
      |> assign(:pdf_upload_mode, false)
      |> assign(:errors, [])
      |> put_flash(:info, "Domain configuration generated from PDF successfully!")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pdf_processing_failed, reason}, socket) do
    Logger.error("PDF processing failed: #{inspect(reason)}")

    error_message = case reason do
      :no_api_key_configured -> "LLM API key not configured. Please configure LLM settings first."
      {:llm_call_failed, _} -> "Failed to connect to LLM service. Please check your configuration."
      _ -> "Failed to process PDF. Please ensure the file is valid and try again."
    end

    socket =
      socket
      |> assign(:pdf_processing, false)
      |> assign(:pdf_error, error_message)

    {:noreply, socket}
  end

  defp format_domain_name(domain_name) when is_binary(domain_name) do
    domain_name
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp get_domain_description(domain_atom) do
    case DescriptionGenerator.get_cached_description(domain_atom) do
      {:ok, description} -> description
      {:error, :not_found} -> "No description available"
    end
  end

  defp error_to_string(:too_large), do: "File is too large (max 10MB)"
  defp error_to_string(:not_accepted), do: "File type not accepted (PDF only)"
  defp error_to_string(:too_many_files), do: "Too many files (max 1)"
  defp error_to_string(error), do: "Upload error: #{inspect(error)}"



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
            navigate="/analyze"
            class="btn btn-ghost btn-sm"
            aria_label="Go to analyze page"
            role="menuitem"
          >
            <span class="hero-cpu-chip w-5 h-5" aria-hidden="true"></span>
            Analyze
          </.nav_link>
          <.nav_link
            navigate="/domains"
            class="btn btn-ghost btn-sm"
            aria_current="page"
            aria_label="Current page: Domain management"
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
        <%= if @form_mode == :list do %>
          <!-- Domain List View -->
          <div class="space-y-6">
            <!-- Header -->
            <header class="flex justify-between items-center">
              <div>
                <h1 class="text-3xl font-bold" id="page-title">Domain Management</h1>
                <p class="text-base-content/60 mt-2" aria-describedby="page-title">
                  Manage decision domains and their configurations
                  <%= if length(@domains) > 0 do %>
                    (<%= length(@domains) %> <%= if length(@domains) == 1, do: "domain", else: "domains" %>)
                  <% end %>
                </p>
              </div>
              <div class="flex gap-2">
                <.icon_button
                  name="document-arrow-up"
                  text="From PDF"
                  phx-click="toggle_pdf_upload"
                  class="btn btn-secondary"
                  icon_class="w-5 h-5"
                  aria-label="Create domain from PDF document"
                />
                <.icon_button
                  name="plus"
                  text="New Domain"
                  phx-click="new_domain"
                  class="btn btn-primary"
                  icon_class="w-5 h-5"
                  aria-label="Create a new domain"
                />
              </div>
            </header>

            <!-- PDF Upload Modal -->
            <%= if @pdf_upload_mode do %>
              <div class="card bg-base-100 shadow-xl border-2 border-secondary">
                <div class="card-body">
                  <div class="flex justify-between items-center mb-4">
                    <h2 class="card-title">
                      <span class="hero-document-arrow-up w-6 h-6 text-secondary"></span>
                      Generate Domain from PDF
                    </h2>
                    <button
                      phx-click="cancel_pdf_upload"
                      class="btn btn-ghost btn-sm btn-square"
                      aria-label="Cancel PDF upload"
                    >
                      <span class="hero-x-mark w-5 h-5"></span>
                    </button>
                  </div>

                  <p class="text-sm text-base-content/70 mb-4">
                    Upload a PDF document containing business rules, processes, or decision criteria.
                    Our AI will analyze the document and generate a domain configuration automatically.
                  </p>

                  <%= if @pdf_processing do %>
                    <div class="flex items-center justify-center py-8">
                      <div class="text-center">
                        <span class="loading loading-spinner loading-lg text-secondary"></span>
                        <p class="mt-2 text-base-content/60">Processing PDF and generating domain...</p>
                        <p class="text-xs text-base-content/50">This may take a few moments</p>
                      </div>
                    </div>
                  <% else %>
                    <form phx-submit="process_pdf" phx-change="validate_pdf">
                      <div class="form-control mb-4">
                        <label class="label">
                          <span class="label-text font-semibold">Domain Name</span>
                        </label>
                        <input
                          type="text"
                          name="domain_name"
                          class="input input-bordered"
                          placeholder="e.g., Invoice Processing, Customer Onboarding"
                          required
                        />
                        <label class="label">
                          <span class="label-text-alt">Choose a descriptive name for your domain</span>
                        </label>
                      </div>

                      <div class="form-control mb-4">
                        <label class="label">
                          <span class="label-text font-semibold">PDF Document</span>
                        </label>
                        <div
                          class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center hover:border-secondary transition-colors"
                          phx-drop-target={@uploads.pdf_file.ref}
                        >
                          <.live_file_input upload={@uploads.pdf_file} class="hidden" />
                          <div class="space-y-2">
                            <span class="hero-document-arrow-up w-12 h-12 text-base-content/40 mx-auto block"></span>
                            <p class="text-sm">
                              <button
                                type="button"
                                class="link link-secondary"
                                onclick="document.querySelector('input[type=file]').click()"
                              >
                                Choose a PDF file
                              </button>
                              or drag and drop here
                            </p>
                            <p class="text-xs text-base-content/50">Maximum file size: 10MB</p>
                          </div>
                        </div>

                        <!-- File Preview -->
                        <%= for entry <- @uploads.pdf_file.entries do %>
                          <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg mt-2">
                            <div class="flex items-center gap-2">
                              <span class="hero-document w-5 h-5 text-secondary"></span>
                              <span class="text-sm font-medium"><%= entry.client_name %></span>
                              <span class="text-xs text-base-content/60">
                                (<%= Float.round(entry.client_size / 1024 / 1024, 2) %> MB)
                              </span>
                            </div>
                            <button
                              type="button"
                              phx-click="cancel-upload"
                              phx-value-ref={entry.ref}
                              class="btn btn-ghost btn-xs btn-square"
                              aria-label="Remove file"
                            >
                              <span class="hero-x-mark w-4 h-4"></span>
                            </button>
                          </div>

                          <!-- Upload Progress -->
                          <%= if entry.progress > 0 && entry.progress < 100 do %>
                            <div class="mt-2">
                              <div class="flex justify-between text-xs mb-1">
                                <span>Uploading...</span>
                                <span><%= entry.progress %>%</span>
                              </div>
                              <progress class="progress progress-secondary w-full" value={entry.progress} max="100"></progress>
                            </div>
                          <% end %>

                          <!-- Upload Errors -->
                          <%= for err <- upload_errors(@uploads.pdf_file, entry) do %>
                            <div class="alert alert-error mt-2">
                              <span class="hero-exclamation-triangle w-5 h-5"></span>
                              <span class="text-sm"><%= error_to_string(err) %></span>
                            </div>
                          <% end %>
                        <% end %>

                        <!-- General Upload Errors -->
                        <%= for err <- upload_errors(@uploads.pdf_file) do %>
                          <div class="alert alert-error mt-2">
                            <span class="hero-exclamation-triangle w-5 h-5"></span>
                            <span class="text-sm"><%= error_to_string(err) %></span>
                          </div>
                        <% end %>
                      </div>

                      <div class="card-actions justify-end">
                        <button
                          type="button"
                          phx-click="cancel_pdf_upload"
                          class="btn btn-ghost"
                        >
                          Cancel
                        </button>
                        <button
                          type="submit"
                          class="btn btn-secondary"
                          disabled={length(@uploads.pdf_file.entries) == 0}
                        >
                          <span class="hero-sparkles w-5 h-5"></span>
                          Generate Domain
                        </button>
                      </div>
                    </form>
                  <% end %>

                  <!-- PDF Processing Error -->
                  <%= if @pdf_error do %>
                    <div class="alert alert-error mt-4">
                      <span class="hero-exclamation-triangle w-6 h-6"></span>
                      <div>
                        <h3 class="font-bold">PDF Processing Failed</h3>
                        <p class="text-sm"><%= @pdf_error %></p>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <!-- Description Generation Error -->
            <%= if @description_error do %>
              <% {failed_domain, error_message} = @description_error %>
              <div class="alert alert-error shadow-lg animate-fade-in">
                <span class="hero-exclamation-triangle w-6 h-6 flex-shrink-0"></span>
                <div class="flex-1">
                  <h3 class="font-bold">Description Generation Failed</h3>
                  <p class="text-sm">
                    Failed to generate description for <%= format_domain_name(Atom.to_string(failed_domain)) %>: <%= error_message %>
                  </p>
                </div>
                <button
                  phx-click="clear_description_error"
                  class="btn btn-ghost btn-sm btn-square"
                  title="Dismiss error"
                >
                  <span class="hero-x-mark w-4 h-4"></span>
                </button>
              </div>
            <% end %>

            <!-- Enhanced Domains Grid with Decision Tables -->
            <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
              <%= for domain <- @domains do %>
                <div class="domain-card card bg-base-100 shadow-xl hover:shadow-2xl transition-all duration-300">
                  <div class="card-body">
                    <!-- Domain Header -->
                    <div class="flex justify-between items-start mb-4">
                      <div class="flex-1">
                        <h2 class="card-title text-xl mb-2">
                          <span class="hero-building-office w-7 h-7 text-primary"></span>
                          <%= domain.display_name %>
                        </h2>
                        <div class="space-y-2">
                          <p class="text-sm text-base-content/70 leading-relaxed">
                            <%= if domain.description && String.trim(domain.description) != "" do %>
                              <%= domain.description %>
                            <% else %>
                              <span class="italic text-base-content/50">No description available</span>
                            <% end %>
                          </p>

                          <!-- AI Generated Description -->
                          <%= case get_domain_description(String.to_atom(domain.name)) do %>
                            <% "No description available" -> %>
                              <div class="flex items-center gap-2 mt-2">
                                <%= if @generating_description == String.to_atom(domain.name) do %>
                                  <div class="flex items-center gap-2 text-info">
                                    <span class="loading loading-spinner loading-xs"></span>
                                    <span class="text-xs">Generating AI description...</span>
                                  </div>
                                <% else %>
                                  <button
                                    phx-click="generate_description"
                                    phx-value-domain={domain.name}
                                    class="btn btn-xs btn-info btn-outline gap-1"
                                  >
                                    <span class="hero-sparkles w-3 h-3"></span>
                                    Generate Description
                                  </button>
                                <% end %>
                              </div>
                            <% ai_description -> %>
                              <div class="bg-info/10 border border-info/20 rounded-lg p-3 mt-2">
                                <div class="flex items-start justify-between gap-2">
                                  <div class="flex-1">
                                    <div class="flex items-center gap-2 mb-1">
                                      <span class="hero-sparkles w-4 h-4 text-info"></span>
                                      <span class="text-xs font-semibold text-info">AI Generated</span>
                                    </div>
                                    <p class="text-xs text-base-content/80 leading-relaxed">
                                      <%= ai_description %>
                                    </p>
                                  </div>
                                  <%= if @generating_description == String.to_atom(domain.name) do %>
                                    <div class="flex items-center gap-1 text-info">
                                      <span class="loading loading-spinner loading-xs"></span>
                                    </div>
                                  <% else %>
                                    <button
                                      phx-click="generate_description"
                                      phx-value-domain={domain.name}
                                      class="btn btn-xs btn-ghost btn-square"
                                      title="Regenerate description"
                                    >
                                      <span class="hero-arrow-path w-3 h-3"></span>
                                    </button>
                                  <% end %>
                                </div>
                              </div>
                          <% end %>
                        </div>
                      </div>
                      <div class="dropdown dropdown-end">
                        <div tabindex="0" role="button" class="btn btn-ghost btn-sm">
                          <span class="hero-ellipsis-vertical w-5 h-5"></span>
                        </div>
                        <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52">
                          <li>
                            <button
                              phx-click="edit_domain"
                              phx-value-domain={domain.name}
                              class="flex items-center gap-2"
                            >
                              <span class="hero-pencil w-4 h-4"></span>
                              Edit Domain
                            </button>
                          </li>
                          <li>
                            <%= if @generating_description == String.to_atom(domain.name) do %>
                              <div class="flex items-center gap-2 text-info px-3 py-2">
                                <span class="loading loading-spinner loading-xs"></span>
                                <span class="text-sm">Generating...</span>
                              </div>
                            <% else %>
                              <button
                                phx-click="generate_description"
                                phx-value-domain={domain.name}
                                class="flex items-center gap-2 text-info"
                              >
                                <span class="hero-sparkles w-4 h-4"></span>
                                Generate Description
                              </button>
                            <% end %>
                          </li>
                          <li>
                            <button
                              phx-click="show_delete_modal"
                              phx-value-domain={domain.name}
                              class="flex items-center gap-2 text-error"
                            >
                              <span class="hero-trash w-4 h-4"></span>
                              Delete Domain
                            </button>
                          </li>
                        </ul>
                      </div>
                    </div>

                    <!-- Quick Stats -->
                    <div class="flex items-center gap-4 mb-4">
                      <div class="stats stats-horizontal shadow-sm bg-base-200/50">
                        <div class="stat py-2 px-4">
                          <div class="stat-title text-xs">Signal Fields</div>
                          <div class="stat-value text-sm text-primary"><%= length(domain.signals_fields) %></div>
                        </div>
                        <div class="stat py-2 px-4">
                          <div class="stat-title text-xs">Patterns</div>
                          <div class="stat-value text-sm text-secondary"><%= length(domain.patterns) %></div>
                        </div>
                      </div>
                      <div class="text-xs text-base-content/50 font-mono">
                        <%= domain.name %>
                      </div>
                    </div>

                    <!-- Decision Table Toggle -->
                    <div class="divider my-2">
                      <button
                        phx-click="toggle_domain_details"
                        phx-value-domain={domain.name}
                        class="btn btn-ghost btn-sm gap-2"
                      >
                        <span class="hero-table-cells w-4 h-4"></span>
                        Decision Table
                        <%= if @expanded_domain == String.to_atom(domain.name) do %>
                          <span class="hero-chevron-up w-4 h-4"></span>
                        <% else %>
                          <span class="hero-chevron-down w-4 h-4"></span>
                        <% end %>
                      </button>
                    </div>

                    <!-- Expandable Decision Table -->
                    <%= if @expanded_domain == String.to_atom(domain.name) do %>
                      <div class="decision-table-container animate-fade-in">
                        <.decision_table patterns={domain.patterns} max_patterns={5} class="shadow-sm" />
                      </div>
                    <% end %>

                    <!-- Action Buttons -->
                    <div class="card-actions justify-end mt-4 pt-4 border-t border-base-200">
                      <button
                        phx-click="edit_domain"
                        phx-value-domain={domain.name}
                        class="btn btn-sm btn-primary btn-outline gap-2"
                      >
                        <span class="hero-pencil w-4 h-4"></span>
                        Edit
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>

              <%= if length(@domains) == 0 do %>
                <div class="col-span-full">
                  <div class="card bg-base-100 shadow-xl">
                    <div class="card-body text-center py-12">
                      <span class="hero-building-office w-16 h-16 mx-auto text-base-content/30 mb-4"></span>
                      <h3 class="text-xl font-semibold mb-2">No domains configured</h3>
                      <p class="text-base-content/60 mb-6">
                        Create your first domain to get started with decision management.
                      </p>
                      <button
                        phx-click="new_domain"
                        class="btn btn-primary"
                      >
                        <span class="hero-plus w-5 h-5"></span>
                        Create First Domain
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <!-- Domain Form View -->
          <div class="space-y-6">
            <!-- Header -->
            <div class="flex justify-between items-center">
              <div>
                <h1 class="text-3xl font-bold">
                  <%= if @form_mode == :new, do: "Create Domain", else: "Edit Domain" %>
                </h1>
                <p class="text-base-content/60 mt-2">
                  <%= if @form_mode == :new do %>
                    Configure a new decision domain with signals and patterns
                  <% else %>
                    Modify the domain configuration and patterns
                  <% end %>
                </p>
              </div>
              <button
                phx-click="cancel"
                class="btn btn-ghost"
              >
                <span class="hero-x-mark w-5 h-5"></span>
                Cancel
              </button>
            </div>

            <!-- Enhanced Error Display -->
            <%= if length(@errors) > 0 do %>
              <div class="alert alert-error shadow-lg animate-fade-in">
                <span class="hero-exclamation-triangle w-6 h-6 flex-shrink-0"></span>
                <div class="flex-1">
                  <h3 class="font-bold text-lg mb-2">Validation Errors</h3>
                  <div class="space-y-1">
                    <%= for error <- @errors do %>
                      <div class="flex items-start gap-2">
                        <span class="hero-x-circle w-4 h-4 flex-shrink-0 mt-0.5 opacity-70"></span>
                        <span class="text-sm"><%= error %></span>
                      </div>
                    <% end %>
                  </div>
                </div>
                <button
                  phx-click="clear_errors"
                  class="btn btn-ghost btn-sm btn-square"
                  title="Dismiss errors"
                >
                  <span class="hero-x-mark w-4 h-4"></span>
                </button>
              </div>
            <% end %>

            <!-- Domain Form -->
            <form phx-submit="save_domain" class="space-y-6">
              <!-- Basic Information -->
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title">
                    <span class="hero-information-circle w-6 h-6"></span>
                    Basic Information
                  </h2>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">Domain Name *</span>
                      </label>
                      <input
                        type="text"
                        name="domain[name]"
                        class="input input-bordered"
                        placeholder="e.g., ai_platform"
                        value={@form_data.name}
                        required
                      />
                      <label class="label">
                        <span class="label-text-alt">Lowercase with underscores (used for file names)</span>
                      </label>
                    </div>

                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">Display Name *</span>
                      </label>
                      <input
                        type="text"
                        name="domain[display_name]"
                        class="input input-bordered"
                        placeholder="e.g., AI Platform"
                        value={@form_data.display_name}
                        required
                      />
                      <label class="label">
                        <span class="label-text-alt">Human-readable name for the UI</span>
                      </label>
                    </div>
                  </div>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Description</span>
                    </label>
                    <textarea
                      name="domain[description]"
                      class="textarea textarea-bordered h-24"
                      placeholder="Describe what this domain is used for..."
                    ><%= @form_data.description %></textarea>
                  </div>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Schema Module</span>
                    </label>
                    <input
                      type="text"
                      name="domain[schema_module]"
                      class="input input-bordered"
                      placeholder="e.g., DecisionEngine.SignalsSchema.AiPlatform"
                      value={@form_data.schema_module}
                    />
                    <label class="label">
                      <span class="label-text-alt">Elixir module name for the schema (optional)</span>
                    </label>
                  </div>
                </div>
              </div>

              <!-- Signal Fields -->
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <div class="flex justify-between items-center mb-4">
                    <h2 class="card-title">
                      <span class="hero-signal w-6 h-6 text-info"></span>
                      Signal Fields
                    </h2>
                    <button
                      type="button"
                      phx-click="add_signal_field"
                      class="btn btn-sm btn-info btn-outline gap-2"
                    >
                      <span class="hero-plus w-4 h-4"></span>
                      Add Field
                    </button>
                  </div>

                  <div class="signal-fields-container space-y-3">
                    <%= for {field, index} <- Enum.with_index(@form_data.signals_fields) do %>
                      <div class="signal-field-row flex gap-2 items-center p-3 bg-base-50 rounded-lg border border-base-200 hover:border-info/30 transition-colors">
                        <div class="flex-shrink-0">
                          <span class="badge badge-info badge-sm"><%= index + 1 %></span>
                        </div>
                        <input
                          type="text"
                          name={"domain[signals_fields][#{index}]"}
                          class="input input-bordered input-sm flex-1"
                          placeholder="e.g., workload_type, complexity_level, user_skill"
                          value={field}
                          phx-change="update_signal_field"
                          phx-value-index={index}
                        />
                        <%= if length(@form_data.signals_fields) > 1 do %>
                          <button
                            type="button"
                            phx-click="remove_signal_field"
                            phx-value-index={index}
                            class="btn btn-sm btn-error btn-outline btn-square"
                            title="Remove field"
                          >
                            <span class="hero-trash w-4 h-4"></span>
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <div class="alert alert-info mt-4">
                    <span class="hero-information-circle w-5 h-5"></span>
                    <div class="text-sm">
                      <p class="font-semibold mb-1">Signal fields define what information the LLM extracts from scenarios.</p>
                      <p class="text-xs opacity-80">Examples: workload_type, complexity_level, user_skill, integration_type</p>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Decision Patterns -->
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <div class="flex justify-between items-center mb-4">
                    <h2 class="card-title">
                      <span class="hero-puzzle-piece w-6 h-6 text-secondary"></span>
                      Decision Patterns
                    </h2>
                    <button
                      type="button"
                      phx-click="add_pattern"
                      class="btn btn-sm btn-secondary btn-outline gap-2"
                    >
                      <span class="hero-plus w-4 h-4"></span>
                      Add Pattern
                    </button>
                  </div>

                  <div class="patterns-container space-y-6">
                    <%= for {pattern, index} <- Enum.with_index(@form_data.patterns) do %>
                      <div class="pattern-card border-2 border-base-200 rounded-xl p-6 bg-gradient-to-br from-base-50 to-base-100 hover:border-secondary/30 transition-all duration-300">
                        <div class="flex justify-between items-center mb-6">
                          <div class="flex items-center gap-3">
                            <div class="badge badge-secondary badge-lg font-bold">
                              <%= index + 1 %>
                            </div>
                            <h3 class="text-lg font-semibold text-base-content">
                              Decision Pattern
                            </h3>
                          </div>
                          <%= if length(@form_data.patterns) > 1 do %>
                            <button
                              type="button"
                              phx-click="remove_pattern"
                              phx-value-index={index}
                              class="btn btn-sm btn-error btn-outline btn-square"
                              title="Remove pattern"
                            >
                              <span class="hero-trash w-4 h-4"></span>
                            </button>
                          <% end %>
                        </div>

                        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
                          <!-- Left Column -->
                          <div class="space-y-4">
                            <div class="form-control">
                              <label class="label">
                                <span class="label-text font-semibold">Pattern ID *</span>
                                <span class="label-text-alt text-xs">Unique identifier</span>
                              </label>
                              <input
                                type="text"
                                name={"domain[patterns][#{index}][id]"}
                                class="input input-bordered"
                                placeholder="e.g., power_automate_good_fit"
                                value={pattern["id"]}
                                phx-change="update_pattern_field"
                                phx-value-index={index}
                                phx-value-field="id"
                                required
                              />
                            </div>

                            <div class="form-control">
                              <label class="label">
                                <span class="label-text font-semibold">Outcome *</span>
                                <span class="label-text-alt text-xs">Recommendation result</span>
                              </label>
                              <input
                                type="text"
                                name={"domain[patterns][#{index}][outcome]"}
                                class="input input-bordered"
                                placeholder="e.g., prefer_power_automate"
                                value={pattern["outcome"]}
                                phx-change="update_pattern_field"
                                phx-value-index={index}
                                phx-value-field="outcome"
                                required
                              />
                            </div>
                          </div>

                          <!-- Right Column -->
                          <div class="space-y-4">
                            <div class="form-control">
                              <label class="label">
                                <span class="label-text font-semibold">Confidence Score *</span>
                                <span class="label-text-alt text-xs">0.0 - 1.0</span>
                              </label>
                              <div class="flex items-center gap-3">
                                <input
                                  type="range"
                                  min="0"
                                  max="1"
                                  step="0.1"
                                  class="range range-secondary flex-1"
                                  value={pattern["score"]}
                                  phx-change="update_pattern_field"
                                  phx-value-index={index}
                                  phx-value-field="score"
                                />
                                <div class="badge badge-secondary badge-lg font-mono">
                                  <%= Float.round(pattern["score"] || 0.5, 1) %>
                                </div>
                              </div>
                              <input
                                type="hidden"
                                name={"domain[patterns][#{index}][score]"}
                                value={pattern["score"]}
                              />
                            </div>

                            <div class="form-control">
                              <label class="label">
                                <span class="label-text font-semibold">Summary *</span>
                                <span class="label-text-alt text-xs">Brief description</span>
                              </label>
                              <textarea
                                name={"domain[patterns][#{index}][summary]"}
                                class="textarea textarea-bordered h-20 resize-none"
                                placeholder="Brief description of when this recommendation applies..."
                                phx-change="update_pattern_field"
                                phx-value-index={index}
                                phx-value-field="summary"
                                required
                              ><%= pattern["summary"] %></textarea>
                            </div>
                          </div>
                        </div>

                        <!-- Pattern Preview -->
                        <%= if pattern["id"] && pattern["outcome"] && pattern["summary"] do %>
                          <div class="mt-6 p-4 bg-base-200/50 rounded-lg border border-base-300">
                            <div class="flex items-center gap-2 mb-2">
                              <span class="hero-eye w-4 h-4 text-base-content/60"></span>
                              <span class="text-sm font-semibold text-base-content/60">Pattern Preview</span>
                            </div>
                            <div class="text-sm">
                              <div class="flex items-center gap-2 mb-1">
                                <span class="badge badge-outline badge-xs font-mono"><%= pattern["id"] %></span>
                                <span class="text-base-content/80">→</span>
                                <span class="font-semibold"><%= pattern["outcome"] %></span>
                                <div class="radial-progress text-xs ml-2"
                                     style={"--value:#{trunc((pattern["score"] || 0.5) * 100)}; --size:1.5rem;"}
                                     role="progressbar">
                                  <%= trunc((pattern["score"] || 0.5) * 100) %>%
                                </div>
                              </div>
                              <p class="text-base-content/70 text-xs italic"><%= pattern["summary"] %></p>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <div class="alert alert-info mt-6">
                    <span class="hero-information-circle w-5 h-5"></span>
                    <div class="text-sm">
                      <p class="font-semibold mb-1">Decision patterns define the core recommendation logic.</p>
                      <p class="text-xs opacity-80">Each pattern represents a specific scenario where a particular outcome is recommended. Conditions (use_when/avoid_when) will be configured through the rule configuration files.</p>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Form Actions -->
              <div class="flex justify-end gap-4">
                <button
                  type="button"
                  phx-click="cancel"
                  class="btn btn-ghost"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="btn btn-primary"
                >
                  <span class="hero-check w-5 h-5"></span>
                  <%= if @form_mode == :new, do: "Create Domain", else: "Save Changes" %>
                </button>
              </div>
            </form>
          </div>
        <% end %>
      </div>

      <!-- Delete Confirmation Modal -->
      <%= if @show_delete_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Confirm Deletion</h3>
            <p class="py-4">
              Are you sure you want to delete the domain "<%= format_domain_name(@domain_to_delete) %>"?
              This action cannot be undone and will remove all associated configuration.
            </p>
            <div class="modal-action">
              <button
                phx-click="hide_delete_modal"
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button
                phx-click="confirm_delete_domain"
                class="btn btn-error"
              >
                <span class="hero-trash w-5 h-5"></span>
                Delete Domain
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
