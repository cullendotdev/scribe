defmodule SocialScribe.SalesforceApiTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceApi
  import SocialScribe.AccountsFixtures
  import Tesla.Mock

  setup do
    user = user_fixture()

    credential = %SocialScribe.Accounts.UserCredential{
      user_id: user.id,
      provider: "salesforce",
      uid: "sf123",
      token: "valid_token",
      refresh_token: "refresh_token",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      meta: %{"instance_url" => "https://na1.salesforce.com"}
    }

    %{credential: credential}
  end

  test "display_properties/0 returns correct properties" do
    properties = SalesforceApi.display_properties()
    assert properties.label == "Salesforce"
    assert properties.initial == "S"
    assert properties.color == "bg-[#00A1E0]"
  end

  describe "search_contacts/2" do
    test "searches for contacts successfully", %{credential: credential} do
      mock(fn
        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/search/"} = env ->
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
        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/search/"} ->
          json(%{"searchRecords" => []}, status: 200)
      end)

      {:ok, results} = SalesforceApi.search_contacts(credential, "Unknown")
      assert results == []
    end

    test "handles API errors", %{credential: credential} do
      mock(fn
        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/search/"} ->
          json(%{"error" => "invalid_query"}, status: 400)
      end)

      {:error, {:api_error, 400, _body}} = SalesforceApi.search_contacts(credential, "Bad Query")
    end
  end

  describe "get_contact/2" do
    test "retrieves a single contact", %{credential: credential} do
      contact_id = "abc1"

      mock(fn
        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/query/"} = env ->
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
        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/query/"} ->
          json(%{"records" => []}, status: 200)
      end)

      {:error, :not_found} = SalesforceApi.get_contact(credential, "missing_id")
    end
  end

  describe "update_contact/3" do
    test "updates contact properties", %{credential: credential} do
      contact_id = "abc1"
      updates = %{"Title" => "New Title"}

      mock(fn
        %{
          method: :patch,
          url: "https://na1.salesforce.com/services/data/v60.0/sobjects/Contact/abc1"
        } ->
          json(%{}, status: 204)

        %{method: :get, url: "https://na1.salesforce.com/services/data/v60.0/query/"} ->
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
  end

  describe "apply_updates/3" do
    test "filters and applies updates", %{credential: credential} do
      updates_list = [
        %{field: "Title", new_value: "CEO", apply: true},
        %{field: "Department", new_value: "Management", apply: true},
        %{field: "Phone", new_value: "555-9999", apply: false}
      ]

      mock(fn
        %{method: :patch} = env ->
          body = Jason.decode!(env.body)
          assert body["Title"] == "CEO"
          assert body["Department"] == "Management"
          refute Map.has_key?(body, "Phone")
          json(%{}, status: 204)

        %{method: :get} ->
          json(%{"records" => [%{"Id" => "123"}]}, status: 200)
      end)

      SalesforceApi.apply_updates(credential, "123", updates_list)
    end

    test "returns no_updates if list is empty or nothing applied", %{credential: credential} do
      assert {:ok, :no_updates} = SalesforceApi.apply_updates(credential, "123", [])

      assert {:ok, :no_updates} =
               SalesforceApi.apply_updates(credential, "123", [%{apply: false}])
    end
  end
end
