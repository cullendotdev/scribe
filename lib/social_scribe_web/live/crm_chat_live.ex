defmodule SocialScribeWeb.CrmChatLive do
  @moduledoc """
  LiveView for the CRM Chat sidebar that provides AI-powered Q&A about CRM contacts.

  Features:
  - Inline @mention search for CRM contacts (Salesforce, HubSpot)
  - Meeting transcript context integration
  - Multi-model AI chat (Gemini 2.5 variants)
  - Session persistence and history
  - Stale data detection and refresh
  """
  use SocialScribeWeb, :live_view

  alias SocialScribe.Accounts
  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.Chats
  alias SocialScribe.Meetings

  require Logger

  # Supported providers mapping to their implementation modules.
  # We look up the configured module to allow mocking in tests.
  defp supported_providers do
    %{
      "salesforce" =>
        Application.get_env(:social_scribe, :salesforce_api, SocialScribe.SalesforceApi),
      "hubspot" => Application.get_env(:social_scribe, :hubspot_api, SocialScribe.HubspotApi)
    }
  end

  def mount(_params, session, socket) do
    socket =
      case session do
        %{"user_id" => user_id} ->
          assign(socket, :current_user, Accounts.get_user!(user_id))

        _ ->
          socket
      end

    if connected?(socket) && Map.get(socket.assigns, :current_user) do
      creds = Accounts.list_user_credentials(socket.assigns.current_user)

      crm_creds =
        Enum.filter(creds, fn c -> Map.has_key?(supported_providers(), c.provider) end)

      # Load recent chat sessions
      sessions = Chats.list_user_chat_sessions(socket.assigns.current_user.id)
      user_meetings = Meetings.list_recent_user_meetings(socket.assigns.current_user)

      {:ok,
       assign(socket,
         query: "",
         contacts: [],
         chat_history: [],
         chat_session_id: nil,
         chat_sessions: sessions,
         user_meetings: user_meetings,
         active_tab: "chat",
         crm_creds: crm_creds,
         searching: false,
         loading_answer: false,
         message: "",
         show_mentions: false,
         mention_query: "",
         selected_contacts: [],
         # Accumulated sources from all contacts mentioned in this session
         accumulated_sources: [],
         show_context_menu: false,
         show_meeting_selector: false,
         # Model selection
         selected_model: "gemini-2.5-flash-lite",
         show_model_selector: false,
         form: to_form(%{"message" => ""}),
         crm_search_status: %{},
         search_id: 0,
         highlighted_index: 0,
         error_alert: nil
       )}
    else
      {:ok,
       assign(socket,
         query: "",
         contacts: [],
         chat_history: [],
         chat_sessions: [],
         chat_session_id: nil,
         active_tab: "chat",
         searching: false,
         loading_answer: false,
         message: "",
         show_mentions: false,
         mention_query: "",
         selected_contacts: [],
         accumulated_sources: [],
         show_context_menu: false,
         show_meeting_selector: false,
         user_meetings: [],
         selected_model: "gemini-2.5-flash-lite",
         show_model_selector: false,
         crm_creds: [],
         form: to_form(%{"message" => ""}),
         crm_search_status: %{},
         search_id: 0,
         highlighted_index: 0,
         error_alert: nil
       )}
    end
  end

  def handle_event("dismiss_error", _, socket) do
    {:noreply, assign(socket, error_alert: nil)}
  end

  def handle_event("toggle_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("toggle_model_selector", _, socket) do
    {:noreply, assign(socket, show_model_selector: !socket.assigns.show_model_selector)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected_model: model, show_model_selector: false)}
  end

  # Create a new chat session effectively by clearing out the current session ID
  def handle_event("new_chat", _, socket) do
    {:noreply,
     assign(socket,
       chat_session_id: nil,
       chat_history: [],
       active_tab: "chat",
       message: "",
       selected_contacts: [],
       accumulated_sources: [],
       error_alert: nil
     )}
  end

  def handle_event("load_session", %{"id" => id}, socket) do
    # Usually comes as string from phx-value-id
    id = String.to_integer(id)
    session = Chats.get_chat_session(id)

    if session && session.user_id == socket.assigns.current_user.id do
      history =
        Enum.map(session.messages, fn m ->
          %{
            role: String.to_atom(m.role),
            content: m.content,
            inserted_at: m.inserted_at,
            sources: if(m.context_data, do: m.context_data["contacts"] || [], else: [])
          }
        end)

      # Load accumulated sources from the session
      accumulated_sources = Chats.get_session_sources(id)

      {:noreply,
       assign(socket,
         chat_session_id: session.id,
         chat_history: history,
         active_tab: "chat",
         accumulated_sources: accumulated_sources,
         error_alert: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_contacts_direct", %{"query" => query}, socket) do
    # Increment search_id to invalidate any flighting requests
    search_id = socket.assigns.search_id + 1

    if query != "" do
      send(self(), {:search_contacts, query, search_id})
    end

    {:noreply,
     assign(socket,
       mention_query: query,
       show_mentions: true,
       contacts: [],
       crm_search_status: if(query == "", do: %{}, else: socket.assigns.crm_search_status),
       search_id: search_id,
       highlighted_index: 0
     )}
  end

  def handle_event("validate_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("handle_keydown", %{"key" => "ArrowDown"}, socket) do
    if socket.assigns.show_mentions and Enum.any?(socket.assigns.contacts) do
      count = Enum.count(socket.assigns.contacts)
      new_index = rem(socket.assigns.highlighted_index + 1, count)
      {:noreply, assign(socket, highlighted_index: new_index)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("handle_keydown", %{"key" => "ArrowUp"}, socket) do
    if socket.assigns.show_mentions and Enum.any?(socket.assigns.contacts) do
      count = Enum.count(socket.assigns.contacts)

      new_index =
        if(socket.assigns.highlighted_index <= 0,
          do: count - 1,
          else: socket.assigns.highlighted_index - 1
        )

      {:noreply, assign(socket, highlighted_index: new_index)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("handle_keydown", %{"key" => "Tab"}, socket) do
    if socket.assigns.show_mentions and Enum.any?(socket.assigns.contacts) do
      contact = Enum.at(socket.assigns.contacts, socket.assigns.highlighted_index)

      handle_event(
        "select_contact",
        %{"id" => contact.id, "provider" => contact.provider},
        socket
      )
    else
      {:noreply, socket}
    end
  end

  # Default keydown handler
  def handle_event("handle_keydown", _, socket), do: {:noreply, socket}

  def handle_event("add_context", _, socket) do
    {:noreply, assign(socket, show_context_menu: !socket.assigns.show_context_menu)}
  end

  def handle_event("toggle_meeting_selector", _, socket) do
    {:noreply, socket}
  end

  def handle_event("select_meeting", %{"id" => id}, socket) do
    meeting = Meetings.get_meeting_with_details(id)

    if meeting do
      source = %{
        provider: "google_meet",
        id: meeting.id,
        firstname: "Meeting:",
        lastname: meeting.title,
        meeting: meeting
      }

      updated_contacts = [source | socket.assigns.selected_contacts] |> Enum.uniq_by(& &1.id)

      {:noreply,
       assign(socket,
         selected_contacts: updated_contacts
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_context_menu", _, socket) do
    {:noreply, assign(socket, show_context_menu: false)}
  end

  def handle_event("close_meeting_selector", _, socket) do
    {:noreply, assign(socket, show_meeting_selector: false)}
  end

  def handle_event("close_mentions", _, socket) do
    {:noreply, assign(socket, show_mentions: false)}
  end

  def handle_event("select_contact", %{"id" => id, "provider" => provider}, socket) do
    contact =
      Enum.find(socket.assigns.contacts, fn c -> c.id == id and c.provider == provider end)

    if contact do
      updated_contacts = [contact | socket.assigns.selected_contacts] |> Enum.uniq_by(& &1.id)

      {:noreply,
       assign(socket,
         selected_contacts: updated_contacts,
         show_mentions: false,
         contacts: [],
         search_id: socket.assigns.search_id + 1
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_contact", %{"id" => id, "provider" => provider}, socket) do
    id = to_string(id)

    updated_contacts =
      Enum.reject(socket.assigns.selected_contacts, fn c ->
        to_string(c[:id] || c["id"]) == id and (c[:provider] || c["provider"]) == provider
      end)

    {:noreply, assign(socket, selected_contacts: updated_contacts)}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if message == "" do
      {:noreply, socket}
    else
      # Use ALL selected contacts instead of just the first one
      contacts = socket.assigns.selected_contacts

      user = socket.assigns.current_user

      # Persistence: Create session if needed
      session_id =
        if socket.assigns.chat_session_id do
          socket.assigns.chat_session_id
        else
          {:ok, session} = create_session(user, message)
          session.id
        end

      # Accumulate sources: merge new contacts into accumulated sources
      new_accumulated =
        (socket.assigns.accumulated_sources ++ contacts)
        |> Enum.uniq_by(&contact_key/1)

      # Update session sources in database for persistence
      if Enum.any?(contacts) do
        Chats.update_session_sources(session_id, contacts)
      end

      # Store sources for this message
      sources = extract_provider_sources(contacts)

      # Persist User Message with source contacts info
      {:ok, _} =
        Chats.add_message_to_session(session_id, %{
          role: "user",
          content: message,
          context_data: %{"sources" => sources, "contacts" => contacts}
        })

      # Reload sessions to show new one in list or update timestamps
      sessions = Chats.list_user_chat_sessions(user.id)

      history =
        socket.assigns.chat_history ++
          [%{role: :user, content: message, inserted_at: DateTime.utc_now(), sources: contacts}]

      # Build conversation history for AI (previous messages only, not current)
      conversation_for_ai =
        Enum.map(socket.assigns.chat_history, fn msg ->
          %{role: msg.role, content: msg.content}
        end)

      socket =
        assign(socket,
          chat_history: history,
          loading_answer: true,
          message: "",
          form: to_form(%{"message" => ""}),
          selected_contacts: [],
          accumulated_sources: new_accumulated,
          chat_session_id: session_id,
          chat_sessions: sessions,
          # Clear cached meetings if needed, or keep them
          user_meetings: [],
          show_context_menu: false
        )
        |> push_event("clear-input", %{})

      pid = self()
      selected_model = socket.assigns.selected_model

      # Pass ALL accumulated sources to the AI, not just current message's contacts
      Task.start(fn ->
        result =
          AIContentGeneratorApi.answer_crm_question(
            message,
            conversation_for_ai,
            new_accumulated,
            selected_model
          )

        send(pid, {:ai_response, result, new_accumulated})
      end)

      {:noreply, socket}
    end
  end

  def handle_info({:ai_response, result, contacts}, socket) do
    sources = extract_provider_sources(contacts)

    case result do
      {:ok, answer} ->
        if socket.assigns.chat_session_id do
          Chats.add_message_to_session(socket.assigns.chat_session_id, %{
            role: "assistant",
            content: answer,
            context_data: %{"sources" => sources, "contacts" => contacts}
          })
        end

        history =
          socket.assigns.chat_history ++
            [
              %{
                role: :assistant,
                content: answer,
                inserted_at: DateTime.utc_now(),
                sources: contacts
              }
            ]

        {:noreply, assign(socket, chat_history: history, loading_answer: false)}

      {:error, error} ->
        Logger.error("AI Error: #{inspect(error)}")

        error_alert = format_ai_error(error, socket.assigns.selected_model)

        {:noreply, assign(socket, error_alert: error_alert, loading_answer: false)}
    end
  end

  def handle_info({:search_contacts, query, search_id}, socket) do
    # Only proceed if this matches the latest search request
    if search_id == socket.assigns.search_id do
      search_term = if query == "", do: "%", else: query
      pid = self()

      # Initialize searching status for each provider
      statuses =
        socket.assigns.crm_creds
        |> Enum.map(fn cred -> {cred.provider, :loading} end)
        |> Enum.into(%{})

      for cred <- socket.assigns.crm_creds do
        Task.start(fn ->
          module = supported_providers()[cred.provider]

          results =
            case module.search_contacts(cred, search_term) do
              {:ok, contacts} -> contacts
              _ -> []
            end

          send(pid, {:contacts_result, search_id, cred.provider, results})
        end)
      end

      {:noreply, assign(socket, crm_search_status: statuses)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:contacts_result, search_id, provider, results}, socket) do
    # Only append results if they belong to the CURRENT active search
    if search_id == socket.assigns.search_id do
      # Avoid duplicates by checking existing contacts
      existing_ids = Enum.map(socket.assigns.contacts, & &1.id)
      new_results = Enum.reject(results, &(&1.id in existing_ids))

      updated_contacts = (socket.assigns.contacts ++ new_results) |> Enum.take(20)
      updated_status = Map.put(socket.assigns.crm_search_status, provider, :done)

      {:noreply,
       assign(socket,
         contacts: updated_contacts,
         crm_search_status: updated_status
       )}
    else
      # Ignore stale results from previous searches
      {:noreply, socket}
    end
  end

  # Extracts unique provider names from a list of contacts
  defp extract_provider_sources(contacts) when is_list(contacts) do
    contacts
    |> Enum.map(fn c -> c[:provider] || c["provider"] end)
    |> Enum.uniq()
  end

  defp extract_provider_sources(_), do: []

  # Creates a unique key tuple for a contact
  defp contact_key(contact) do
    {contact[:provider] || contact["provider"], contact[:id] || contact["id"]}
  end

  defp create_session(user, first_message) do
    title =
      String.slice(first_message, 0, 50) <>
        if String.length(first_message) > 50, do: "...", else: ""

    Chats.create_chat_session(%{user_id: user.id, title: title})
  end

  # Format AI error messages for user display - returns structured data for card rendering
  defp format_ai_error(
         {:api_error, 429, %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}},
         model
       ) do
    %{
      type: :quota_exceeded,
      title: "Quota Exceeded",
      message:
        "The daily quota for this model has been reached. This typically resets at midnight Pacific Time.",
      suggestion: "Try switching to a different model to continue chatting.",
      model: friendly_model_name(model)
    }
  end

  defp format_ai_error({:api_error, 429, _body}, model) do
    %{
      type: :rate_limited,
      title: "Rate Limited",
      message: "Too many requests for this model.",
      suggestion: "Please try a different model or wait a moment before trying again.",
      model: friendly_model_name(model)
    }
  end

  defp format_ai_error(_error, _model) do
    %{
      type: :error,
      title: "Something went wrong",
      message: "Sorry, I had trouble processing that request.",
      suggestion: "Please try again.",
      model: nil
    }
  end

  defp friendly_model_name("gemini-2.5-flash"), do: "Gemini 2.5 Flash"
  defp friendly_model_name("gemini-2.5-flash-lite"), do: "Gemini 2.5 Flash Lite"
  defp friendly_model_name(model), do: model

  def provider_props("google_meet") do
    %{color: "bg-blue-600", initial: "M", label: "MeetingTranscript"}
  end

  def provider_props("salesforce") do
    %{color: "bg-blue-500", initial: "S", label: "Salesforce"}
  end

  def provider_props("hubspot") do
    %{color: "bg-orange-500", initial: "H", label: "HubSpot"}
  end

  def provider_props(provider) do
    if module = supported_providers()[provider] do
      module.display_properties()
    else
      %{color: "bg-gray-500", initial: "?", label: "Unknown"}
    end
  end

  def provider_color(provider), do: provider_props(provider).color
  def provider_initial(provider), do: provider_props(provider).initial

  @doc """
  Returns the initials (up to 2 characters) for a contact.
  For meetings, returns "M". For contacts, returns first letters of first and last name.
  """
  def contact_initials(contact) when is_map(contact) do
    provider = contact[:provider] || contact["provider"]

    if provider == "google_meet" do
      "M"
    else
      first = contact[:firstname] || contact["firstname"] || ""
      last = contact[:lastname] || contact["lastname"] || ""

      initials =
        [first, last]
        |> Enum.map(&String.first/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join()
        |> String.upcase()

      if initials == "", do: "?", else: String.slice(initials, 0, 2)
    end
  end

  def contact_initials(_), do: "?"

  @doc """
  Returns the full name for a contact for display in tooltips.
  """
  def contact_full_name(contact) when is_map(contact) do
    provider = contact[:provider] || contact["provider"]

    if provider == "google_meet" do
      meeting = contact[:meeting] || contact["meeting"]

      title =
        cond do
          is_struct(meeting) -> meeting.title
          is_map(meeting) -> meeting["title"] || meeting[:title]
          true -> nil
        end

      "Meeting: #{title || "Transcript"}"
    else
      first = contact[:firstname] || contact["firstname"] || ""
      last = contact[:lastname] || contact["lastname"] || ""
      "#{first} #{last}" |> String.trim()
    end
  end

  def contact_full_name(_), do: "Unknown"

  attr :content, :string, required: true
  attr :sources, :list, default: []

  defp markdown(assigns) do
    # Configure Earmark options for safety and features if needed
    html = Earmark.as_html!(assigns.content)

    # If we have sources, replace contact names with styled chip HTML
    html =
      if Enum.any?(assigns.sources) do
        inject_contact_chips(html, assigns.sources)
      else
        html
      end

    assigns = assign(assigns, :html, html)

    ~H"""
    <div class="markdown-content">
      {Phoenix.HTML.raw(@html)}
    </div>
    """
  end

  # Injects styled contact chip HTML when contact names are found in the content.
  # This is a very crude way to do it, but it works (for now).
  defp inject_contact_chips(html, sources) do
    # Sort by name length (longest first) to match longer names before shorter ones
    sorted_sources =
      sources
      |> Enum.sort_by(fn contact -> -String.length(contact_full_name(contact)) end)

    Enum.reduce(sorted_sources, html, fn contact, acc ->
      name = contact_full_name(contact)
      provider = contact[:provider] || contact["provider"]
      initials = contact_initials(contact)
      color = provider_color(provider)

      chip_html =
        if provider == "google_meet" do
          ~s(<span class="inline-flex items-center gap-1 bg-gray-100 rounded-lg pl-0.5 pr-2 py-0.5 mb-1 align-middle"><span class="w-4 h-4 rounded-full flex items-center justify-center bg-blue-600 shrink-0"><svg class="w-2 h-2 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg></span><span class="text-gray-700 text-sm">#{name}</span></span>)
        else
          ~s(<span class="inline-flex items-center gap-1 bg-gray-100 rounded-lg pl-0.5 pr-2 py-0.5 mb-1 align-middle"><span class="w-4 h-4 rounded-full flex items-center justify-center text-[7px] text-white font-bold shrink-0 #{color}">#{initials}</span><span class="text-gray-700 text-sm">#{name}</span></span>)
        end

      # Replace the name with the chip HTML (case insensitive, but preserve original casing is tricky)
      # Using a simple string replacement - only replace if not already inside a tag.
      String.replace(acc, name, chip_html)
    end)
  end

  # Renders message content with @mentions displayed as styled contact chips.
  # The sources list contains contact data that was tagged in the message.
  attr :content, :string, required: true
  attr :sources, :list, default: []

  defp message_with_mentions(assigns) do
    # Build a map of contact names to their data for lookup
    contact_map =
      assigns.sources
      |> Enum.map(fn contact ->
        name = contact_full_name(contact)
        {name, contact}
      end)
      |> Enum.into(%{})

    # Parse the content and split into parts (text and mentions)
    parts = parse_mentions(assigns.content, contact_map)
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span>
      <%= for part <- @parts do %>
        <%= case part do %>
          <% {:text, text} -> %>
            {text}
          <% {:mention, name, contact} -> %>
            <span class="inline-flex items-center gap-1 bg-white/80 rounded-lg pl-0.5 pr-2 py-0.5 mb-1 align-middle">
              <%= if contact[:provider] == "google_meet" do %>
                <span class="w-4 h-4 rounded-full flex items-center justify-center bg-blue-600 shrink-0">
                  <.icon name="hero-video-camera" class="w-2 h-2 text-white" />
                </span>
              <% else %>
                <span class={"w-4 h-4 rounded-full flex items-center justify-center text-[7px] text-white font-bold shrink-0 #{provider_color(contact[:provider] || contact["provider"])}"}>
                  {contact_initials(contact)}
                </span>
              <% end %>
              <span class="text-gray-700 text-sm">{name}</span>
            </span>
        <% end %>
      <% end %>
    </span>
    """
  end

  # Parses message content and returns a list of {:text, string} or {:mention, name, contact} tuples
  defp parse_mentions(content, contact_map) do
    if map_size(contact_map) == 0 do
      [{:text, content}]
    else
      # Sort contact names by length (longest first) to match longer names before shorter ones
      sorted_names = contact_map |> Map.keys() |> Enum.sort_by(&(-String.length(&1)))

      # Find all mentions with their positions
      mentions =
        sorted_names
        |> Enum.flat_map(fn name ->
          mention_pattern = "@#{name}"
          find_all_occurrences(content, mention_pattern, name, contact_map)
        end)
        |> Enum.sort_by(fn {start, _, _, _} -> start end)
        |> remove_overlapping_mentions([])

      if Enum.empty?(mentions) do
        [{:text, content}]
      else
        build_parts_from_mentions(content, mentions, 0, [])
      end
    end
  end

  # Find all occurrences of a mention pattern in the content
  defp find_all_occurrences(content, pattern, name, contact_map) do
    case :binary.matches(content, pattern) do
      [] ->
        []

      matches ->
        Enum.map(matches, fn {start, len} ->
          {start, start + len, name, Map.get(contact_map, name)}
        end)
    end
  end

  # Remove overlapping mentions (keep earlier/longer ones)
  defp remove_overlapping_mentions([], acc), do: Enum.reverse(acc)

  defp remove_overlapping_mentions([mention | rest], acc) do
    {_start, end_pos, _name, _contact} = mention

    # Filter out any mentions that would overlap with this one
    filtered_rest = Enum.reject(rest, fn {s, _, _, _} -> s < end_pos end)
    remove_overlapping_mentions(filtered_rest, [mention | acc])
  end

  # Build parts from the sorted, non-overlapping mentions
  defp build_parts_from_mentions(content, [], pos, acc) do
    remaining = String.slice(content, pos..-1//1)

    if remaining == "" do
      Enum.reverse(acc)
    else
      Enum.reverse([{:text, remaining} | acc])
    end
  end

  defp build_parts_from_mentions(content, [{start, end_pos, name, contact} | rest], pos, acc) do
    # Add text before this mention
    acc =
      if start > pos do
        text = String.slice(content, pos..(start - 1)//1)
        [{:text, text} | acc]
      else
        acc
      end

    # Add the mention
    acc = [{:mention, name, contact} | acc]

    build_parts_from_mentions(content, rest, end_pos, acc)
  end
end
