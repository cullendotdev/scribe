defmodule SocialScribeWeb.CrmChatLiveTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import Mox
  import ExUnit.CaptureLog

  @endpoint SocialScribeWeb.Endpoint

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "CRM Chat" do
    test "renders chat page with placeholder", %{conn: conn, user: user} do
      {:ok, _view, html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      assert html =~ "Ask Anything"
    end

    test "Salesforce contact search displays results in mentions menu", %{conn: conn, user: user} do
      # Setup credentials
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "John" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "John",
             lastname: "Doe",
             provider: "salesforce",
             email: "john@example.com"
           }
         ]}
      end)
      |> stub(:get_contact_notes, fn _creds, _id -> {:ok, []} end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Simulate search trigger (via JS hook)
      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "John"})

      # Wait for async search result
      assert has_element?(view, "#mentions-menu")
      assert has_element?(view, ".mention-item", "John Doe")
    end

    test "Salesforce contact selection adds to sources list", %{conn: conn, user: user} do
      # Setup credentials
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "John" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "John",
             lastname: "Doe",
             provider: "salesforce",
             email: "john@example.com"
           }
         ]}
      end)
      |> stub(:get_contact_notes, fn _creds, _id -> {:ok, []} end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Search and Select
      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "John"})

      # Wait for results and click
      # NOTE: render_click sends the event to the server.
      # The template creates buttons for contacts in the dropdown.
      view
      |> element("button[phx-click=select_contact]", "John Doe")
      |> render_click()

      # Check if added to sources list
      assert has_element?(view, "button[phx-click=remove_contact][title='Remove John Doe']")
    end

    test "sends message and receives AI response", %{conn: conn, user: user} do
      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, _contacts, _model ->
        {:ok, "This is the AI response."}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Submit message
      view
      |> form("form[phx-submit=send_message]", %{message: "Hello AI"})
      |> render_submit()

      # Check user message appears
      assert has_element?(view, "#chat-scroller", "Hello AI")

      # Check input is cleared
      assert has_element?(view, "textarea[name=message]", "")

      # Check AI response appears (async) - has_element? retries automatically
      assert has_element?(view, "#chat-scroller", "This is the AI response.")
    end

    test "loads and displays session history from database", %{conn: conn, user: user} do
      # Create session and messages
      {:ok, session} =
        SocialScribe.Chats.create_chat_session(%{user_id: user.id, title: "Test Session"})

      SocialScribe.Chats.add_message_to_session(session.id, %{
        role: "user",
        content: "Past Question"
      })

      SocialScribe.Chats.add_message_to_session(session.id, %{
        role: "assistant",
        content: "Past Answer"
      })

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Switch to history tab
      render_click(view, "toggle_tab", %{"tab" => "history"})

      # Check session listed
      assert has_element?(view, "button[phx-click=load_session]", "Test Session")

      # Click session to load
      render_click(view, "load_session", %{"id" => to_string(session.id)})

      # Assert chat loaded
      assert has_element?(view, "#chat-scroller", "Past Question")
      assert has_element?(view, "#chat-scroller", "Past Answer")
    end

    test "meeting selection adds transcript to sources list", %{conn: conn, user: user} do
      import SocialScribe.MeetingsFixtures

      meeting =
        meeting_fixture(
          calendar_event_id:
            SocialScribe.CalendarFixtures.calendar_event_fixture(user_id: user.id).id
        )

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Open context menu and select meeting (simulated)
      # Since the meeting list is populated on mount, we can just trigger the event
      render_click(view, "select_meeting", %{"id" => meeting.id})

      # The button has an icon, so we check for the title attribute which contains the name
      assert has_element?(
               view,
               "button[phx-click=remove_contact][title='Remove Meeting: #{meeting.title}']"
             )
    end

    test "removes Salesforce contact from sources list", %{conn: conn, user: user} do
      # Setup credentials and mock
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "John" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "John",
             lastname: "Doe",
             provider: "salesforce",
             email: "john@example.com"
           }
         ]}
      end)
      |> stub(:get_contact_notes, fn _creds, _id -> {:ok, []} end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Add contact first
      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "John"})

      view
      |> element("button[phx-click=select_contact]", "John Doe")
      |> render_click()

      assert has_element?(view, "button[phx-click=remove_contact][title='Remove John Doe']")

      # Remove contact
      view
      |> element("button[phx-click=remove_contact][title='Remove John Doe']")
      |> render_click()

      refute has_element?(view, "button[phx-click=remove_contact][title='Remove John Doe']")
    end

    test "new chat button clears current session and shows empty state", %{conn: conn, user: user} do
      # Create session and history
      {:ok, session} =
        SocialScribe.Chats.create_chat_session(%{user_id: user.id, title: "Old Session"})

      SocialScribe.Chats.add_message_to_session(session.id, %{
        role: "user",
        content: "Old Message"
      })

      # Start with a specific session loaded
      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Load the session - pass ID as string because LiveView expects string from params
      render_click(view, "toggle_tab", %{"tab" => "history"})
      render_click(view, "load_session", %{"id" => to_string(session.id)})

      assert has_element?(view, "#chat-scroller", "Old Message")

      # Click New Chat
      render_click(view, "new_chat")

      refute has_element?(view, "#chat-scroller", "Old Message")
      assert has_element?(view, "#chat-scroller", "Start a new conversation")
    end

    test "displays error alert when AI quota is exceeded", %{conn: conn, user: user} do
      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, _contacts, _model ->
        {:error, {:api_error, 429, %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}}}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Submit message and check error alert (async)
      assert capture_log(fn ->
               view
               |> form("form[phx-submit=send_message]", %{message: "Hello AI"})
               |> render_submit()

               assert has_element?(view, "div", "Quota Exceeded")
             end) =~ "AI Error"
    end

    test "model selector changes AI model for generation", %{conn: conn, user: user} do
      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, _contacts, "gemini-2.5-flash" ->
        {:ok, "Response from Flash"}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Open selector and select model
      render_click(view, "toggle_model_selector")
      render_click(view, "select_model", %{"model" => "gemini-2.5-flash"})

      # Submit message
      view
      |> form("form[phx-submit=send_message]", %{message: "Hello"})
      |> render_submit()

      assert has_element?(view, "#chat-scroller", "Response from Flash")
    end

    test "AI response renders with markdown formatting", %{conn: conn, user: user} do
      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, _contacts, _model ->
        {:ok, "**Bold** and *Italic*"}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> form("form[phx-submit=send_message]", %{message: "Format check"})
      |> render_submit()

      assert has_element?(view, ".markdown-content strong", "Bold")
      assert has_element?(view, ".markdown-content em", "Italic")
    end

    test "deletes chat session with modal confirmation", %{conn: conn, user: user} do
      # Create session
      {:ok, session} =
        SocialScribe.Chats.create_chat_session(%{user_id: user.id, title: "To Be Deleted"})

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Switch to history
      render_click(view, "toggle_tab", %{"tab" => "history"})

      assert has_element?(view, "button[phx-click=load_session]", "To Be Deleted")

      # Delete session
      view
      |> element("button[phx-click=prompt_delete_chat][phx-value-id=#{session.id}]")
      |> render_click()

      # Check for modal
      assert has_element?(view, "#delete-chat-modal", "Delete chat?")

      # Confirm delete
      view
      |> element("button[phx-click=confirm_delete_chat]")
      |> render_click()

      refute has_element?(view, "button[phx-click=load_session]", "To Be Deleted")

      # Verify deletion from database
      assert_raise Ecto.NoResultsError, fn ->
        SocialScribe.Chats.get_chat_session!(session.id)
      end
    end

    test "sidebar collapse toggle changes collapsed state", %{conn: conn, user: user} do
      {:ok, view, html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Initially expanded - should see collapse button
      assert html =~ "Collapse Sidebar"
      refute html =~ "Expand CRM Chat"

      # Toggle to collapsed
      html = render_click(view, "toggle_collapse")

      # Should see expand button now
      assert html =~ "Expand CRM Chat"
      refute html =~ "Collapse Sidebar"

      # Toggle back to expanded
      html = render_click(view, "toggle_collapse")
      assert html =~ "Collapse Sidebar"
    end

    test "keyboard ArrowDown navigates through mention suggestions", %{conn: conn, user: user} do
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "Test" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "Test",
             lastname: "One",
             provider: "salesforce",
             email: "t1@example.com"
           },
           %{
             id: "2",
             firstname: "Test",
             lastname: "Two",
             provider: "salesforce",
             email: "t2@example.com"
           }
         ]}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "Test"})

      # Use the specific index highlighting class or attribute to verify selection
      # Assuming the first item is index 0 and highlighted
      assert has_element?(view, ".mention-item.bg-gray-100", "Test One")

      # Move down to second item
      render_click(view, "handle_keydown", %{"key" => "ArrowDown"})

      # Second item should be highlighted
      assert has_element?(view, ".mention-item.bg-gray-100", "Test Two")
    end

    test "keyboard ArrowUp navigates mentions with wrap-around to last item", %{
      conn: conn,
      user: user
    } do
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "Test" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "Test",
             lastname: "One",
             provider: "salesforce",
             email: "t1@example.com"
           },
           %{
             id: "2",
             firstname: "Test",
             lastname: "Two",
             provider: "salesforce",
             email: "t2@example.com"
           }
         ]}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "Test"})

      # Initial state (index 0 highlighted)
      assert has_element?(view, ".mention-item.bg-gray-100", "Test One")

      # Up from top should wrap to bottom (last item)
      render_click(view, "handle_keydown", %{"key" => "ArrowUp"})

      # Last item highlighted
      assert has_element?(view, ".mention-item.bg-gray-100", "Test Two")
    end

    test "keyboard Tab selects currently highlighted contact", %{conn: conn, user: user} do
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "John" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "John",
             lastname: "Doe",
             provider: "salesforce",
             email: "john@example.com"
           }
         ]}
      end)
      |> stub(:get_contact_notes, fn _creds, _id -> {:ok, []} end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "John"})

      render_click(view, "handle_keydown", %{"key" => "Tab"})

      assert has_element?(view, "button[phx-click=remove_contact][title='Remove John Doe']")
    end

    test "cancel delete modal keeps session intact", %{conn: conn, user: user} do
      {:ok, session} =
        SocialScribe.Chats.create_chat_session(%{user_id: user.id, title: "Keep Me"})

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      render_click(view, "toggle_tab", %{"tab" => "history"})

      view
      |> element("button[phx-click=prompt_delete_chat][phx-value-id=#{session.id}]")
      |> render_click()

      assert has_element?(view, "#delete-chat-modal")

      render_click(view, "cancel_delete_chat")

      assert has_element?(view, "button[phx-click=load_session]", "Keep Me")
      assert SocialScribe.Chats.get_chat_session(session.id) != nil
    end

    test "HubSpot contact search displays results in mentions menu", %{conn: conn, user: user} do
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "hubspot",
          uid: "hs_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _creds, "Jane" ->
        {:ok,
         [
           %{
             id: "hs1",
             firstname: "Jane",
             lastname: "Smith",
             provider: "hubspot",
             email: "jane@example.com"
           }
         ]}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "Jane"})

      assert has_element?(view, ".mention-item", "Jane Smith")
    end

    test "empty message submission is ignored and creates no session", %{conn: conn, user: user} do
      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> form("form[phx-submit=send_message]", %{message: ""})
      |> render_submit()

      sessions = SocialScribe.Chats.list_user_chat_sessions(user.id)
      assert Enum.empty?(sessions)
    end

    test "cannot load another user's session (security)", %{conn: conn, user: user} do
      other_user = SocialScribe.AccountsFixtures.user_fixture()

      {:ok, other_session} =
        SocialScribe.Chats.create_chat_session(%{user_id: other_user.id, title: "Secret"})

      SocialScribe.Chats.add_message_to_session(other_session.id, %{
        role: "user",
        content: "Private message"
      })

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      render_click(view, "load_session", %{"id" => to_string(other_session.id)})

      refute has_element?(view, "#chat-scroller", "Private message")
    end

    test "selected sources persist in database across messages", %{conn: conn, user: user} do
      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, "John" ->
        {:ok,
         [
           %{
             id: "1",
             firstname: "John",
             lastname: "Doe",
             provider: "salesforce",
             email: "john@example.com"
           }
         ]}
      end)
      |> stub(:get_contact_notes, fn _creds, _id -> {:ok, []} end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, _contacts, _model ->
        {:ok, "Response about John"}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "John"})

      view
      |> element("button[phx-click=select_contact]", "John Doe")
      |> render_click()

      view
      |> form("form[phx-submit=send_message]", %{message: "Tell me about @John Doe"})
      |> render_submit()

      assert has_element?(view, "#chat-scroller", "Response about John")

      sessions = SocialScribe.Chats.list_user_chat_sessions(user.id)
      session = hd(sessions)
      sources = SocialScribe.Chats.get_session_sources(session.id)

      assert length(sources) == 1
      assert hd(sources)["firstname"] == "John"
    end

    test "fetches and includes contact notes in AI context", %{conn: conn, user: user} do
      Mox.set_mox_global(SocialScribe.SalesforceApiMock)
      test_pid = self()

      {:ok, _} =
        SocialScribe.Accounts.create_user_credential(%{
          user_id: user.id,
          provider: "salesforce",
          uid: "sf_uid",
          token: "tok",
          refresh_token: "ref",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          email: "user@example.com"
        })

      # Mock Salesforce API to return notes
      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _creds, _query ->
        {:ok,
         [
           %{
             id: "sf_bob",
             firstname: "Bob",
             lastname: "Builder",
             provider: "salesforce",
             email: "bob@example.com"
           }
         ]}
      end)
      |> expect(:get_contact_notes, fn _creds, "sf_bob" ->
        {:ok, [%{title: "Secret", body: "Bob likes bricks"}]}
      end)

      # Mock AI to report back what it received
      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, contacts, _model ->
        send(test_pid, {:ai_request_received, contacts})
        {:ok, "AI Response"}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # 1. Search for contact
      view
      |> element("#chat-input-wrapper")
      |> render_hook("search_contacts_direct", %{"query" => "Bob"})

      # Select Contact (direct hook to avoid race conditions with UI rendering)
      render_hook(view, "select_contact", %{"id" => "sf_bob", "provider" => "salesforce"})

      # 3. Wait for notes to be loaded (async task)
      Process.sleep(300)

      # 4. Send message to trigger AI generation
      view
      |> form("form[phx-submit=send_message]", %{message: "Analyze Bob"})
      |> render_submit()

      # 5. Verify the AI received the contact WITH the notes
      assert_receive {:ai_request_received, contacts}, 1000

      bob = Enum.find(contacts, fn c -> c[:id] == "sf_bob" end)
      assert bob, "Contact Bob should be in the AI context"

      notes = bob["notes"]
      assert is_list(notes), "Notes should be a list"
      assert length(notes) == 1
      assert hd(notes).body == "Bob likes bricks"
    end
  end
end
