defmodule DecisionEngineWeb.DomainManagementLive do
  use DecisionEngineWeb, :live_view
  alias DecisionEngine.DomainManager
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

  defp format_domain_name(domain_name) when is_binary(domain_name) do
    domain_name
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
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
          <.nav_link navigate="/" class="btn btn-ghost btn-sm">
            <span class="hero-home w-5 h-5"></span>
            Home
          </.nav_link>
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
        <%= if @form_mode == :list do %>
          <!-- Domain List View -->
          <div class="space-y-6">
            <!-- Header -->
            <div class="flex justify-between items-center">
              <div>
                <h1 class="text-3xl font-bold">Domain Management</h1>
                <p class="text-base-content/60 mt-2">Manage decision domains and their configurations</p>
              </div>
              <button
                phx-click="new_domain"
                class="btn btn-primary"
              >
                <span class="hero-plus w-5 h-5"></span>
                New Domain
              </button>
            </div>

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
                        <p class="text-sm text-base-content/70 leading-relaxed">
                          <%= domain.description %>
                        </p>
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
