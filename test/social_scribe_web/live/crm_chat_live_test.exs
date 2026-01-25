defmodule SocialScribeWeb.CrmChatLiveTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import Mox

  @endpoint SocialScribeWeb.Endpoint

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "CRM Chat" do
    test "renders chat page", %{conn: conn, user: user} do
      {:ok, _view, html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      assert html =~ "Ask Anything"
    end

    test "search and select contact", %{conn: conn, user: user} do
      # Create credentials for the user
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

      {:ok, _view, html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      assert html =~ "Ask Anything"
    end

    test "trigger search and display results", %{conn: conn, user: user} do
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

    test "select contact adds to selected list", %{conn: conn, user: user} do
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

    test "sends message and displays AI response", %{conn: conn, user: user} do
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

      # Check AI response appears (async) - has_element? retries automatically
      assert has_element?(view, "#chat-scroller", "This is the AI response.")
    end

    test "loads session history", %{conn: conn, user: user} do
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

    test "select meeting adds to selected list", %{conn: conn, user: user} do
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

    test "remove contact from selected list", %{conn: conn, user: user} do
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

    test "start new chat clears history", %{conn: conn, user: user} do
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

    test "displays error when AI fails", %{conn: conn, user: user} do
      SocialScribe.AIContentGeneratorMock
      |> expect(:answer_crm_question, fn _msg, _hist, _contacts, _model ->
        {:error, {:api_error, 429, %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}}}
      end)

      {:ok, view, _html} =
        live_isolated(conn, SocialScribeWeb.CrmChatLive, session: %{"user_id" => user.id})

      # Submit message
      view
      |> form("form[phx-submit=send_message]", %{message: "Hello AI"})
      |> render_submit()

      # Check error alert appears (async)
      assert has_element?(view, "div", "Quota Exceeded")
    end

    test "selects different model and uses it for generation", %{conn: conn, user: user} do
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

    test "renders markdown formatted response", %{conn: conn, user: user} do
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
  end
end
