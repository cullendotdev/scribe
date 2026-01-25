defmodule SocialScribeWeb.CrmComponents do
  @moduledoc """
  Reusable UI components for CRM integrations.
  """
  use SocialScribeWeb, :html

  import SocialScribeWeb.ModalComponents

  alias SocialScribe.Crm.Config

  @doc """
  Renders a CRM integration card.
  """
  attr :provider, :string, required: true
  # Meeting ID or struct
  attr :meeting, :any, required: true

  def crm_integration_card(assigns) do
    config = Config.get(assigns.provider)
    assigns = assign(assigns, :config, config)

    ~H"""
    <div class="bg-white shadow-xl rounded-lg p-6 md:p-8">
      <div class="flex justify-between items-center">
        <div>
          <h2 class="text-2xl font-semibold text-slate-700">{@config.label} Integration</h2>
          <p class="text-sm text-slate-500 mt-1">
            Update {@config.label} contacts with information from this meeting
          </p>
        </div>
        <.link
          patch={
            if @provider == "hubspot",
              do: ~p"/dashboard/meetings/#{@meeting}/hubspot",
              else: ~p"/dashboard/meetings/#{@meeting}/salesforce"
          }
          class={[
            "inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white transition-colors",
            @config.button_class
          ]}
        >
          <svg class="w-5 h-5 mr-2" fill="currentColor" viewBox="0 0 24 24">
            <path d={@config.icon_path} />
          </svg>
          Update {@config.label} Contact
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  Renders a global CRM modal that handles provider-specific wrappers.
  Uses Config to dynamically select the appropriate modal wrapper component.
  """
  attr :provider, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :any, required: true
  attr :meeting, :any, required: true
  attr :credential, :any, required: true

  def crm_modal(assigns) do
    config = Config.get(assigns.provider)
    modal_wrapper = Config.modal_wrapper(assigns.provider)

    assigns =
      assigns
      |> assign(:config, config)
      |> assign(:modal_wrapper, modal_wrapper)

    ~H"""
    <%= case @modal_wrapper do %>
      <% :hubspot_modal -> %>
        <.hubspot_modal id={"#{@provider}-modal-wrapper"} show={@show} on_cancel={@on_cancel}>
          <.live_component
            module={@config.modal_component}
            id={"#{@provider}-modal"}
            provider={@provider}
            meeting={@meeting}
            credential={@credential}
            modal_id={"#{@provider}-modal-wrapper"}
          />
        </.hubspot_modal>
      <% :salesforce_modal -> %>
        <.salesforce_modal id={"#{@provider}-modal-wrapper"} show={@show} on_cancel={@on_cancel}>
          <.live_component
            module={@config.modal_component}
            id={"#{@provider}-modal"}
            provider={@provider}
            meeting={@meeting}
            credential={@credential}
            modal_id={"#{@provider}-modal-wrapper"}
          />
        </.salesforce_modal>
      <% _ -> %>
        <!-- No modal wrapper for this provider -->
    <% end %>
    """
  end

  @doc """
  Returns the initials (up to 2 characters) for a contact.
  """
  def contact_initials(%{provider: "google_meet"}), do: "M"

  def contact_initials(contact) when is_map(contact) do
    first = contact[:firstname] || contact["firstname"]
    last = contact[:lastname] || contact["lastname"]
    name = contact[:name] || contact["name"]

    initials =
      cond do
        (first && first != "") || (last && last != "") ->
          [first || "", last || ""]
          |> Enum.map(&String.first/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.join()

        name && name != "" ->
          name
          |> String.split()
          |> Enum.map(&String.first/1)
          |> Enum.take(2)
          |> Enum.join()

        true ->
          "?"
      end
      |> String.upcase()

    if initials == "", do: "?", else: String.slice(initials, 0, 2)
  end

  def contact_initials(_), do: "?"

  @doc """
  Returns the full name for a contact for display.
  """
  def contact_full_name(contact) when is_map(contact) do
    provider = contact[:provider] || contact["provider"]

    if provider == "google_meet" do
      meeting = contact[:meeting] || contact["meeting"]
      title = if is_struct(meeting), do: meeting.title, else: meeting["title"] || meeting[:title]
      "Meeting: #{title || "Transcript"}"
    else
      first = contact[:firstname] || contact["firstname"]
      last = contact[:lastname] || contact["lastname"]
      name = contact[:name] || contact["name"]

      if((first || last) in [nil, ""],
        do: name,
        else: "#{first} #{last}" |> String.trim()
      ) || "Unknown"
    end
  end

  def contact_full_name(_), do: "Unknown"

  @doc """
  Renders a contact chip with provider icon.
  """
  attr :contact, :map, required: true
  attr :mode, :atom, default: :inline, values: [:inline, :block]

  def crm_contact_chip(assigns) do
    provider = assigns.contact[:provider] || assigns.contact["provider"]
    assigns = assign(assigns, :provider, provider)
    assigns = assign(assigns, :name, contact_full_name(assigns.contact))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-lg pl-0.5 pr-2 py-0.5 mb-1 align-middle",
      if(@mode == :inline, do: "bg-white/80", else: "bg-gray-100")
    ]}>
      <.crm_icon provider={@provider} contact={@contact} class="w-4 h-4 text-[7px]" />
      <span class="text-gray-700 text-sm">{@name}</span>
    </span>
    """
  end

  @doc """
  Renders a provider icon or avatar initials.
  """
  attr :provider, :string, required: true
  attr :contact, :map, default: nil
  attr :class, :string, default: "w-5 h-5 text-[10px]"

  def crm_icon(assigns) do
    config = Config.get(assigns.provider)
    initials = if assigns.contact, do: contact_initials(assigns.contact), else: config.initial

    assigns = assign(assigns, :config, config)
    assigns = assign(assigns, :initials, initials)

    ~H"""
    <div class={[
      "rounded-full flex items-center justify-center font-bold text-white shrink-0",
      @class,
      @config.color
    ]}>
      <%= if @provider == "google_meet" do %>
        <.icon name="hero-video-camera" class="w-[60%] h-[60%] text-white" />
      <% else %>
        <span>{@initials}</span>
      <% end %>
    </div>
    """
  end
end
