defmodule SocialScribeWeb.CrmChatLiveTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import Mox

  @endpoint SocialScribeWeb.Endpoint

  setup :verify_on_exit!

  describe "CRM Chat" do
    test "renders chat page", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Ask Anything"
    end

    test "search and select contact", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

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

      SocialScribe.SalesforceApiMock
      |> stub(:display_properties, fn ->
        %{color: "bg-blue", initial: "S", label: "Salesforce"}
      end)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Ask Anything"

      # TODO: Add integration tests for:
      # - @mention search triggering and displaying results
      # - Contact selection updating the message
      # - Message submission and AI response display
      # - Session history loading
    end
  end
end
