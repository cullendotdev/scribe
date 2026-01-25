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

  import SocialScribeWeb.CrmComponents

  alias SocialScribe.Accounts
  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.Chats
  alias SocialScribe.Meetings
  alias SocialScribe.Crm.Config

  require Logger

  def mount(_params, session, socket) do
    socket =
      case session do
        %{"user_id" => user_id} ->
          assign(socket, :current_user, Accounts.get_user!(user_id))

        _ ->
          socket
      end

    socket = assign(socket, default_assigns())

    if connected?(socket) && Map.get(socket.assigns, :current_user) do
      user = socket.assigns.current_user
      creds = Accounts.list_user_credentials(user)

      crm_creds =
        Enum.filter(creds, fn c -> c.provider in Config.provider_names() end)

      # Load recent chat sessions and meetings
      sessions = Chats.list_user_chat_sessions(user.id)
      user_meetings = Meetings.list_recent_user_meetings(user)

      {:ok,
       assign(socket,
         chat_sessions: sessions,
         user_meetings: user_meetings,
         crm_creds: crm_creds
       )}
    else
      {:ok, socket}
    end
  end

  # Default assigns for the CRM Chat sidebar
  defp default_assigns do
    [
      query: "",
      contacts: [],
      chat_history: [],
      chat_sessions: [],
      chat_session_id: nil,
      user_meetings: [],
      active_tab: "chat",
      crm_creds: [],
      searching: false,
      loading_answer: false,
      message: "",
      show_mentions: false,
      mention_query: "",
      selected_contacts: [],
      accumulated_sources: [],
      show_context_menu: false,
      show_meeting_selector: false,
      selected_model: "gemini-2.5-flash-lite",
      show_model_selector: false,
      form: to_form(%{"message" => ""}),
      crm_search_status: %{},
      search_id: 0,
      highlighted_index: 0,
      error_alert: nil,
      collapsed: false,
      delete_session_id: nil
    ]
  end

  def handle_event("toggle_collapse", _, socket) do
    {:noreply, assign(socket, collapsed: !socket.assigns.collapsed)}
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

  def handle_event("prompt_delete_chat", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_session_id: String.to_integer(id))}
  end

  def handle_event("cancel_delete_chat", _, socket) do
    {:noreply, assign(socket, delete_session_id: nil)}
  end

  def handle_event("confirm_delete_chat", _, socket) do
    if id = socket.assigns.delete_session_id do
      session = Chats.get_chat_session!(id)

      if session.user_id == socket.assigns.current_user.id do
        Chats.delete_chat_session(session)

        # Refresh list
        sessions = Chats.list_user_chat_sessions(socket.assigns.current_user.id)

        # If we deleted the active session, reset to new chat
        socket =
          if socket.assigns.chat_session_id == session.id do
            assign(socket,
              chat_session_id: nil,
              chat_history: [],
              active_tab: "chat",
              message: "",
              selected_contacts: [],
              accumulated_sources: [],
              error_alert: nil
            )
          else
            socket
          end

        {:noreply, assign(socket, chat_sessions: sessions, delete_session_id: nil)}
      else
        {:noreply, assign(socket, delete_session_id: nil)}
      end
    else
      {:noreply, socket}
    end
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

      # Convert @mentions to token format for display
      message_with_tokens = convert_mentions_to_tokens(message, contacts)

      # Persist User Message with source contacts info (store tokenized version)
      {:ok, _} =
        Chats.add_message_to_session(session_id, %{
          role: "user",
          content: message_with_tokens,
          context_data: %{"sources" => sources, "contacts" => contacts}
        })

      # Reload sessions to show new one in list or update timestamps
      sessions = Chats.list_user_chat_sessions(user.id)

      history =
        socket.assigns.chat_history ++
          [
            %{
              role: :user,
              content: message_with_tokens,
              inserted_at: DateTime.utc_now(),
              sources: contacts
            }
          ]

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
            message_with_tokens,
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
          module = Config.api_impl(cred.provider)

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

  attr :content, :string, required: true
  attr :sources, :list, default: []

  defp markdown(assigns) do
    # parse_source_tokens splits content into a list of parts:
    # [{:text, "some text"}, {:contact, ...}, {:text, " more text"}]
    parts = parse_source_tokens(assigns.content, assigns.sources)
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <div class="markdown-content">
      <%= for part <- @parts do %>
        <%= case part do %>
          <% {:text, text} -> %>
            {render_inline_markdown(text)}
          <% {:contact, provider, id, name} -> %>
            <.crm_contact_chip contact={%{provider: provider, id: id, name: name}} mode={:block} />
          <% {:meeting, id, title} -> %>
            <.crm_contact_chip
              contact={%{provider: "google_meet", id: id, title: title}}
              mode={:block}
            />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_inline_markdown(text) do
    # Render markdown
    html = Earmark.as_html!(text)

    # Check if the original text starts with a newline (indicating an intentional block break)
    # If not, and the HTML starts with a paragraph, we want to "unwrap" that first paragraph
    # so it flows inline with the preceding chip.
    starts_with_newline = Regex.match?(~r/^\s*[\r\n]/, text)

    if !starts_with_newline and String.starts_with?(html, "<p>") do
      # Unwrap the first paragraph to make it inline
      # Use Regex to match only the FIRST paragraph at the start of the string
      Regex.replace(~r/^<p>(.*?)<\/p>/s, html, "\\1", global: false)
      |> Phoenix.HTML.raw()
    else
      Phoenix.HTML.raw(html)
    end
  end

  # Unified component for rendering content with source tokens (works for both user and assistant messages)
  attr :content, :string, required: true
  attr :sources, :list, default: []

  defp render_with_tokens(assigns) do
    parts = parse_source_tokens(assigns.content, assigns.sources)
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span>
      <%= for part <- @parts do %>
        <%= case part do %>
          <% {:text, text} -> %>
            {text}
          <% {:contact, provider, id, name} -> %>
            <.crm_contact_chip contact={%{provider: provider, id: id, name: name}} mode={:inline} />
          <% {:meeting, id, title} -> %>
            <.crm_contact_chip
              contact={%{provider: "google_meet", id: id, title: title}}
              mode={:inline}
            />
        <% end %>
      <% end %>
    </span>
    """
  end

  # Converts @Name mentions to [[contact:provider:id:name]] token format
  defp convert_mentions_to_tokens(content, contacts) do
    # Sort by name length (longest first) to match longer names before shorter ones
    sorted_contacts =
      contacts
      |> Enum.sort_by(fn c -> -String.length(contact_full_name(c)) end)

    Enum.reduce(sorted_contacts, content, fn contact, acc ->
      name = contact_full_name(contact)
      provider = contact[:provider] || contact["provider"]
      id = contact[:id] || contact["id"]

      if provider == "google_meet" do
        String.replace(acc, "@#{name} ", "[[meeting:#{id}:#{name}]] ")
      else
        String.replace(acc, "@#{name} ", "[[contact:#{provider}:#{id}:#{name}]] ")
      end
    end)
  end

  # Parses content for [[contact:...]] and [[meeting:...]] tokens
  # Returns a list of {:text, string}, {:contact, provider, id, name}, or {:meeting, id, title} tuples
  defp parse_source_tokens(content, _sources) do
    # Regex to match [[type:data]] tokens
    # Contact: [[contact:provider:id:name]]
    # Meeting: [[meeting:id:title]]
    token_regex = ~r/\[\[(contact|meeting):([^\]]+)\]\]/

    case Regex.split(token_regex, content, include_captures: true, trim: true) do
      parts when is_list(parts) ->
        Enum.map(parts, fn part ->
          cond do
            String.starts_with?(part, "[[contact:") ->
              parse_contact_token(part)

            String.starts_with?(part, "[[meeting:") ->
              parse_meeting_token(part)

            true ->
              {:text, part}
          end
        end)

      _ ->
        [{:text, content}]
    end
  end

  # Parses [[contact:provider:id:name]] token
  defp parse_contact_token(token) do
    # Extract content between [[ and ]]
    inner = token |> String.trim_leading("[[") |> String.trim_trailing("]]")

    case String.split(inner, ":", parts: 4) do
      ["contact", provider, id, name] ->
        {:contact, provider, id, name}

      _ ->
        {:text, token}
    end
  end

  # Parses [[meeting:id:title]] token
  defp parse_meeting_token(token) do
    inner = token |> String.trim_leading("[[") |> String.trim_trailing("]]")

    case String.split(inner, ":", parts: 3) do
      ["meeting", id, title] ->
        {:meeting, id, title}

      _ ->
        {:text, token}
    end
  end
end
