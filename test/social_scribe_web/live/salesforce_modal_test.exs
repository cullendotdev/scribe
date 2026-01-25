defmodule SocialScribeWeb.SalesforceModalTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import Mox

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  describe "Salesforce Modal" do
    setup %{conn: conn} do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        uid: "sf123",
        token: "token",
        refresh_token: "refresh",
        email: "test@example.com",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
        meta: %{"instance_url" => "https://na1.salesforce.com"}
      }

      {:ok, credential} = SocialScribe.Repo.insert(credential)

      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting,
        credential: credential
      }
    end

    test "renders modal when navigating to salesforce route", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      assert has_element?(view, "#salesforce-modal-wrapper")
      assert has_element?(view, "h2", "Update in Salesforce")
    end

    test "searches for contacts", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      # Expectation for search_contacts
      expect(SocialScribe.SalesforceApiMock, :search_contacts, fn _cred, "John" ->
        {:ok,
         [
           %{
             id: "abc1",
             firstname: "John",
             lastname: "Doe",
             email: "john@example.com",
             display_name: "John Doe"
           }
         ]}
      end)

      # Trigger search input
      view
      |> element("#salesforce-modal-wrapper input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      # Wait for async update
      :timer.sleep(50)

      assert has_element?(view, "button", "John Doe")
    end

    test "generates suggestions on contact selection", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      # 1. Search (Mox)
      expect(SocialScribe.SalesforceApiMock, :search_contacts, fn _cred, "John" ->
        {:ok,
         [
           %{
             id: "123",
             firstname: "John",
             lastname: "Doe",
             email: "john@example.com",
             display_name: "John Doe"
           }
         ]}
      end)

      view
      |> element("#salesforce-modal-wrapper input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      assert has_element?(view, "button", "John Doe")

      # 2. Select (Mox AI)
      expect(SocialScribe.AIContentGeneratorMock, :generate_salesforce_suggestions, fn _ ->
        {:ok, [%{field: "Title", value: "New Title", context: "Context"}]}
      end)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='123']")
      |> render_click()

      :timer.sleep(100)
      assert has_element?(view, "input[value='New Title']")
    end

    test "applies updates", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      # 1. Search (Mox)
      expect(SocialScribe.SalesforceApiMock, :search_contacts, fn _cred, "John" ->
        {:ok,
         [
           %{
             id: "123",
             firstname: "John",
             lastname: "Doe",
             email: "john@example.com",
             display_name: "John Doe"
           }
         ]}
      end)

      view
      |> element("#salesforce-modal-wrapper input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      # 2. Select (Mox AI)
      expect(SocialScribe.AIContentGeneratorMock, :generate_salesforce_suggestions, fn _ ->
        {:ok, [%{field: "Title", value: "CEO", context: "Context"}]}
      end)

      view |> element("button[phx-click='select_contact'][phx-value-id='123']") |> render_click()

      # 3. Apply (Mox Update)
      expect(SocialScribe.SalesforceApiMock, :update_contact, fn _cred, "123", updates ->
        assert updates["Title"] == "CEO"
        {:ok, %{id: "123"}}
      end)

      # Submit form
      view
      |> form("#salesforce-modal-wrapper form", %{
        "apply" => %{"Title" => "1"},
        "values" => %{"Title" => "CEO"}
      })
      |> render_submit()

      assert render(view) =~ "Successfully updated 1 field(s) in Salesforce"
    end
  end

  # Helper function to create a meeting with transcript for testing
  defp meeting_fixture_with_transcript(user) do
    meeting = meeting_fixture(%{})
    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)
    {:ok, _} = SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{"speaker" => "John", "words" => [%{"text" => "Hello"}]}
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end
end
