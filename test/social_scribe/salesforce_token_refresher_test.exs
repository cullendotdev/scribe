defmodule SocialScribe.SalesforceTokenRefresherTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceTokenRefresher
  import SocialScribe.AccountsFixtures
  import Tesla.Mock

  describe "refresh_token/1" do
    test "successfully refreshes token" do
      refresh_token = "valid_refresh_token"

      mock(fn
        %{method: :post, url: "https://login.salesforce.com/services/oauth2/token"} = env ->
          assert env.body =~ "grant_type=refresh_token"
          assert env.body =~ "refresh_token=valid_refresh_token"

          json(
            %{
              "access_token" => "new_access_token",
              "instance_url" => "https://new.salesforce.com",
              "id" => "http://login.salesforce.com/id/123",
              "token_type" => "Bearer",
              "issued_at" => "1234567890",
              "signature" => "sig"
            },
            status: 200
          )
      end)

      {:ok, response} = SalesforceTokenRefresher.refresh_token(refresh_token)
      assert response["access_token"] == "new_access_token"
      assert response["instance_url"] == "https://new.salesforce.com"
    end

    test "handles error response" do
      refresh_token = "invalid_refresh_token"

      mock(fn
        %{method: :post, url: "https://login.salesforce.com/services/oauth2/token"} ->
          json(%{"error" => "invalid_grant"}, status: 400)
      end)

      {:error, {400, body}} = SalesforceTokenRefresher.refresh_token(refresh_token)
      assert body["error"] == "invalid_grant"
    end
  end

  describe "refresh_credential/1" do
    test "updates credential with new token details" do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        token: "old_token",
        refresh_token: "old_refresh",
        email: "test@example.com",
        uid: "sf_123",
        expires_at: DateTime.utc_now() |> DateTime.truncate(:second),
        meta: %{"instance_url" => "https://old.salesforce.com"}
      }

      {:ok, credential} = SocialScribe.Repo.insert(credential)

      mock(fn
        %{method: :post} ->
          json(
            %{
              "access_token" => "new_fresh_token",
              "instance_url" => "https://new.salesforce.com",
              "expires_in" => 3600
            },
            status: 200
          )
      end)

      {:ok, updated_cred} = SalesforceTokenRefresher.refresh_credential(credential)

      assert updated_cred.token == "new_fresh_token"
      assert updated_cred.meta["instance_url"] == "https://new.salesforce.com"

      # Verify DB update
      db_cred = SocialScribe.Repo.get!(SocialScribe.Accounts.UserCredential, credential.id)
      assert db_cred.token == "new_fresh_token"
    end
  end

  describe "ensure_valid_token/1" do
    test "refreshes token if expired" do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        uid: "sf_1",
        email: "test@example.com",
        token: "expired_token",
        refresh_token: "refresh",
        expires_at: DateTime.add(DateTime.utc_now(), -100, :second) |> DateTime.truncate(:second),
        meta: %{}
      }

      {:ok, credential} = SocialScribe.Repo.insert(credential)

      mock(fn %{method: :post} ->
        json(%{"access_token" => "refreshed_token"}, status: 200)
      end)

      {:ok, valid_cred} = SalesforceTokenRefresher.ensure_valid_token(credential)
      assert valid_cred.token == "refreshed_token"
    end

    test "refreshes token if about to expire" do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        uid: "sf_2",
        email: "test@example.com",
        token: "expiring_soon",
        refresh_token: "refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:second),
        meta: %{}
      }

      {:ok, credential} = SocialScribe.Repo.insert(credential)

      mock(fn %{method: :post} ->
        json(%{"access_token" => "refreshed_soon"}, status: 200)
      end)

      {:ok, valid_cred} = SalesforceTokenRefresher.ensure_valid_token(credential)
      assert valid_cred.token == "refreshed_soon"
    end

    test "returns existing credential if valid" do
      user = user_fixture()

      credential = %SocialScribe.Accounts.UserCredential{
        user_id: user.id,
        provider: "salesforce",
        uid: "sf_3",
        email: "test@example.com",
        token: "valid_token",
        refresh_token: "refresh",
        # Expires in 2 hours
        expires_at: DateTime.add(DateTime.utc_now(), 7200, :second) |> DateTime.truncate(:second),
        meta: %{}
      }

      {:ok, credential} = SocialScribe.Repo.insert(credential)

      # Should FAIL if it tries to call API
      mock(fn _ -> raise "Should not make API call" end)

      {:ok, valid_cred} = SalesforceTokenRefresher.ensure_valid_token(credential)
      assert valid_cred.token == "valid_token"
    end
  end
end
