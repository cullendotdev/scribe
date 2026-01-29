defmodule SocialScribe.SalesforceApiTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceApi
  import SocialScribe.AccountsFixtures
  import Tesla.Mock
  import ExUnit.CaptureLog

  # Test constants matching the implementation
  @instance_url "https://na1.salesforce.com"
  @api_version "v60.0"

  # Pre-computed URLs for use in pattern matching
  @search_url "#{@instance_url}/services/data/#{@api_version}/search/"
  @query_url "#{@instance_url}/services/data/#{@api_version}/query/"
  @token_refresh_url "https://login.salesforce.com/services/oauth2/token"

  # Helper function for dynamic sobject URLs
  defp sobject_url(contact_id),
    do: "#{@instance_url}/services/data/#{@api_version}/sobjects/Contact/#{contact_id}"

  setup do
    user = user_fixture()

    credential = %SocialScribe.Accounts.UserCredential{
      user_id: user.id,
      provider: "salesforce",
      uid: "sf123",
      token: "valid_token",
      refresh_token: "refresh_token",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      meta: %{"instance_url" => @instance_url}
    }

    %{credential: credential}
  end

  describe "display_properties/0" do
    test "returns correct properties" do
      properties = SalesforceApi.display_properties()
      assert properties.label == "Salesforce"
      assert properties.initial == "S"
      assert properties.color == "bg-[#00A1E0]"
    end
  end

  describe "search_contacts/2" do
    test "searches for contacts successfully", %{credential: credential} do
      mock(fn
        %{method: :get, url: @search_url} = env ->
          assert env.query[:q] =~ "FIND {John*} IN ALL FIELDS"

          json(
            %{
              "searchRecords" => [
                %{
                  "Id" => "abc1",
                  "FirstName" => "John",
                  "LastName" => "Doe",
                  "Email" => "john@example.com",
                  "Phone" => "555-0100",
                  "MobilePhone" => "555-0101",
                  "Account" => %{"Name" => "Acme Corp"},
                  "Title" => "Manager",
                  "MailingStreet" => "123 Main St",
                  "MailingCity" => "San Francisco",
                  "MailingState" => "CA",
                  "MailingPostalCode" => "94105",
                  "MailingCountry" => "USA",
                  "Department" => "Sales"
                }
              ]
            },
            status: 200
          )
      end)

      {:ok, results} = SalesforceApi.search_contacts(credential, "John")

      assert length(results) == 1
      contact = hd(results)
      assert contact.id == "abc1"
      assert contact.firstname == "John"
      assert contact.lastname == "Doe"
      assert contact.email == "john@example.com"
      assert contact.company == "Acme Corp"
    end

    test "handles empty search results", %{credential: credential} do
      mock(fn
        %{method: :get, url: @search_url} ->
          json(%{"searchRecords" => []}, status: 200)
      end)

      {:ok, results} = SalesforceApi.search_contacts(credential, "Unknown")
      assert results == []
    end

    test "handles API errors", %{credential: credential} do
      mock(fn
        %{method: :get, url: @search_url} ->
          json(%{"error" => "invalid_query"}, status: 400)
      end)

      {:error, {:api_error, 400, _body}} = SalesforceApi.search_contacts(credential, "Bad Query")
    end

    test "handles network errors", %{credential: credential} do
      mock(fn
        %{method: :get, url: @search_url} ->
          {:error, :timeout}
      end)

      {:error, {:http_error, :timeout}} = SalesforceApi.search_contacts(credential, "John")
    end

    test "sanitizes special characters in query", %{credential: credential} do
      mock(fn
        %{method: :get, url: @search_url} = env ->
          # The SOSL query will have { } for syntax, but the search term should be sanitized
          assert env.query[:q] =~ "testquery*"
          # Verify the input braces were removed from the search term
          refute env.query[:q] =~ "test{query"
          json(%{"searchRecords" => []}, status: 200)
      end)

      {:ok, _results} = SalesforceApi.search_contacts(credential, "test{query}")
    end
  end

  describe "get_contact/2" do
    test "retrieves a single contact", %{credential: credential} do
      contact_id = "abc1"

      mock(fn
        %{method: :get, url: @query_url} = env ->
          assert env.query[:q] =~ "SELECT"
          assert env.query[:q] =~ "Id = '#{contact_id}'"

          json(
            %{
              "records" => [
                %{
                  "Id" => contact_id,
                  "FirstName" => "Jane",
                  "LastName" => "Doe",
                  "Email" => "jane@example.com"
                }
              ]
            },
            status: 200
          )
      end)

      {:ok, contact} = SalesforceApi.get_contact(credential, contact_id)
      assert contact.id == contact_id
      assert contact.firstname == "Jane"
    end

    test "returns not found if no records", %{credential: credential} do
      mock(fn
        %{method: :get, url: @query_url} ->
          json(%{"records" => []}, status: 200)
      end)

      {:error, :not_found} = SalesforceApi.get_contact(credential, "missing_id")
    end

    test "handles network errors", %{credential: credential} do
      mock(fn
        %{method: :get, url: @query_url} ->
          {:error, :econnrefused}
      end)

      {:error, {:http_error, :econnrefused}} = SalesforceApi.get_contact(credential, "abc1")
    end
  end

  describe "update_contact/3" do
    test "updates contact properties", %{credential: credential} do
      contact_id = "abc1"
      updates = %{"Title" => "New Title"}

      mock(fn
        %{method: :patch, url: url} ->
          assert url == sobject_url(contact_id)

          json(%{}, status: 204)

        %{method: :get, url: @query_url} ->
          json(
            %{
              "records" => [
                %{
                  "Id" => "abc1",
                  "Title" => "New Title"
                }
              ]
            },
            status: 200
          )
      end)

      {:ok, contact} = SalesforceApi.update_contact(credential, contact_id, updates)
      assert contact.jobtitle == "New Title"
    end

    test "handles update failure", %{credential: credential} do
      mock(fn
        %{method: :patch} ->
          json(%{"error" => "validation_error", "message" => "Invalid field"}, status: 400)
      end)

      {:error, {:api_error, 400, _body}} =
        SalesforceApi.update_contact(credential, "abc1", %{"Title" => ""})
    end

    test "handles network errors during update", %{credential: credential} do
      mock(fn
        %{method: :patch} ->
          {:error, :timeout}
      end)

      {:error, {:http_error, :timeout}} =
        SalesforceApi.update_contact(credential, "abc1", %{"Title" => "CEO"})
    end
  end

  describe "apply_updates/3" do
    test "filters and applies updates", %{credential: credential} do
      updates_list = [
        %{field: "Title", new_value: "CEO", apply: true},
        %{field: "Department", new_value: "Management", apply: true},
        %{field: "Phone", new_value: "555-9999", apply: false}
      ]

      mock(fn
        %{method: :patch, url: url} = env ->
          assert url == sobject_url("123")
          body = Jason.decode!(env.body)
          assert body["Title"] == "CEO"
          assert body["Department"] == "Management"
          refute Map.has_key?(body, "Phone")
          json(%{}, status: 204)

        %{method: :get, url: @query_url} ->
          json(%{"records" => [%{"Id" => "123"}]}, status: 200)
      end)

      assert {:ok, _contact} = SalesforceApi.apply_updates(credential, "123", updates_list)
    end

    test "returns no_updates if list is empty or nothing applied", %{credential: credential} do
      assert {:ok, :no_updates} = SalesforceApi.apply_updates(credential, "123", [])

      assert {:ok, :no_updates} =
               SalesforceApi.apply_updates(credential, "123", [%{apply: false}])
    end

    test "handles errors during apply_updates", %{credential: credential} do
      updates_list = [%{field: "Title", new_value: "CEO", apply: true}]

      mock(fn
        %{method: :patch} ->
          json(%{"error" => "insufficient_permissions"}, status: 403)

        # Mock token refresh attempt (which will also fail)
        %{method: :post, url: @token_refresh_url} ->
          json(%{"error" => "invalid_grant"}, status: 400)
      end)

      assert capture_log(fn ->
               {:error, _reason} = SalesforceApi.apply_updates(credential, "123", updates_list)
             end) =~ "Failed to refresh salesforce token"
    end
  end

  describe "get_contact_notes/2" do
    test "fetches and formats notes", %{credential: credential} do
      contact_id = "abc1"

      mock(fn
        %{method: :get, url: @query_url} = env ->
          assert env.query[:q] =~ "SELECT Id, Title, Body, CreatedDate FROM Note"
          assert env.query[:q] =~ "ParentId = '#{contact_id}'"

          json(
            %{
              "records" => [
                %{
                  "Id" => "note1",
                  "Title" => "Meeting Notes",
                  "Body" => "Good meeting.",
                  "CreatedDate" => "2023-10-27T10:00:00Z"
                }
              ]
            },
            status: 200
          )
      end)

      {:ok, notes} = SalesforceApi.get_contact_notes(credential, contact_id)
      assert length(notes) == 1
      note = hd(notes)
      assert note.id == "note1"
      assert note.title == "Meeting Notes"
      assert note.body == "Good meeting."
    end

    test "handles query errors by returning empty list", %{credential: credential} do
      mock(fn
        %{method: :get, url: @query_url} ->
          json(%{"error" => "invalid"}, status: 400)
      end)

      # Implementation returns empty list on error
      assert capture_log(fn ->
               {:ok, notes} = SalesforceApi.get_contact_notes(credential, "abc1")
               assert notes == []
             end) =~ "Failed to fetch notes"
    end
  end
end
