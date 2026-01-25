defmodule SocialScribe.SalesforceSuggestionsTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceSuggestions
  import SocialScribe.AccountsFixtures
  import Tesla.Mock
  import Mox

  # Make sure mocks are set up
  setup :verify_on_exit!

  describe "generate_suggestions/3" do
    test "generates and merges suggestions" do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        uid: "sf123",
        token: "token",
        refresh_token: "refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        meta: %{"instance_url" => "https://na1.salesforce.com"}
      }

      contact_id = "abc1"
      meeting = %{id: "meeting_123", transcript: "..."}

      # Mock Salesforce API to return a contact
      # Note: SalesforceSuggestions calls SalesforceApi.get_contact directly
      # SalesforceApi calls Tesla.get
      mock(fn
        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/query/"} ->
          json(
            %{
              "records" => [
                %{
                  "Id" => contact_id,
                  "FirstName" => "John",
                  "LastName" => "Doe",
                  "Title" => "Manager"
                }
              ]
            },
            status: 200
          )
      end)

      # Mock AI Generator
      expect(SocialScribe.AIContentGeneratorMock, :generate_salesforce_suggestions, fn ^meeting ->
        {:ok,
         [
           %{field: "Title", value: "Director", context: "Promoted recently"},
           # No change
           %{field: "FirstName", value: "John", context: "Confirmed name"}
         ]}
      end)

      {:ok, result} = SalesforceSuggestions.generate_suggestions(credential, contact_id, meeting)

      assert result.contact.id == contact_id
      assert length(result.suggestions) == 1
      suggestion = hd(result.suggestions)
      assert suggestion.field == "Title"
      assert suggestion.current_value == "Manager"
      assert suggestion.new_value == "Director"
      assert suggestion.has_change == true
    end

    test "handles errors from Salesforce API" do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        token: "token",
        refresh_token: "refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      # Mock Salesforce API error
      mock(fn %{method: :get} ->
        json(%{"error" => "not_found"}, status: 404)
      end)

      {:error, _} = SalesforceSuggestions.generate_suggestions(credential, "bad_id", %{})
    end
  end

  describe "generate_suggestions_from_meeting/1" do
    test "generates suggestions without contact data" do
      meeting = %{}

      expect(SocialScribe.AIContentGeneratorMock, :generate_salesforce_suggestions, fn ^meeting ->
        {:ok,
         [
           %{field: "Email", value: "test@example.com", context: "Email mentioned"}
         ]}
      end)

      {:ok, suggestions} = SalesforceSuggestions.generate_suggestions_from_meeting(meeting)

      assert length(suggestions) == 1
      suggestion = hd(suggestions)
      assert suggestion.field == "Email"
      assert suggestion.new_value == "test@example.com"
      assert suggestion.current_value == nil
      assert suggestion.has_change == true
    end
  end

  describe "merge_with_contact/2" do
    test "merges suggestions with existing contact data" do
      contact = %{
        firstname: "Jane",
        email: "jane@old.com"
      }

      suggestions = [
        # No change
        %{
          field: "FirstName",
          new_value: "Jane",
          apply: true,
          current_value: nil,
          has_change: false
        },
        # Change
        %{
          field: "Email",
          new_value: "jane@new.com",
          apply: true,
          current_value: nil,
          has_change: false
        },
        # New field
        %{field: "Title", new_value: "CEO", apply: true, current_value: nil, has_change: false}
      ]

      merged = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      # Should filter out no-change items (FirstName)
      assert length(merged) == 2

      email_suggestion = Enum.find(merged, &(&1.field == "Email"))
      assert email_suggestion.current_value == "jane@old.com"
      assert email_suggestion.has_change == true

      title_suggestion = Enum.find(merged, &(&1.field == "Title"))
      assert title_suggestion.current_value == nil
      assert title_suggestion.has_change == true
    end
  end
end
