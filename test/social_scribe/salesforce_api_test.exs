defmodule SocialScribe.SalesforceApiTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceApi
  import SocialScribe.AccountsFixtures

  describe "SalesforceApi" do
    test "implements the behaviour" do
      user = user_fixture()

      _credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        uid: "sf123",
        token: "token",
        refresh_token: "refresh",
        expires_at: DateTime.utc_now(),
        meta: %{"instance_url" => "https://na1.salesforce.com"}
      }

      # Just verify functions exist and take correct args
      # We cannot call them safely without patching Tesla or having real creds
      assert Kernel.function_exported?(SalesforceApi, :search_contacts, 2)

      assert Kernel.function_exported?(SalesforceApi, :get_contact, 2)
      assert Kernel.function_exported?(SalesforceApi, :update_contact, 3)

      # Verify behaviour
      behaviours = SalesforceApi.module_info(:attributes)[:behaviour]
      assert SocialScribe.CrmApiBehaviour in behaviours
    end
  end
end
