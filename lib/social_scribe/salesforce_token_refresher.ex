defmodule SocialScribe.SalesforceTokenRefresher do
  @moduledoc """
  Refreshes Salesforce OAuth tokens.
  """

  @salesforce_token_url "https://login.salesforce.com/services/oauth2/token"

  def client do
    Tesla.client([
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON
    ])
  end

  @doc """
  Refreshes a Salesforce access token using the refresh token.
  Returns {:ok, response_body} with new access_token, etc.
  """
  def refresh_token(refresh_token_string) do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    body = %{
      grant_type: "refresh_token",
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token_string
    }

    case Tesla.post(client(), @salesforce_token_url, body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refreshes the token for a Salesforce credential and updates it in the database.
  """
  def refresh_credential(credential) do
    alias SocialScribe.Accounts

    case refresh_token(credential.refresh_token) do
      {:ok, response} ->
        # Salesforce may not return a new refresh token, so keep the old one if not provided
        new_refresh_token = response["refresh_token"] || credential.refresh_token
        
        # Salesforce doesn't always return expires_in, sometimes it's issued_at + session timeout
        # But OAuth2 spec usually returns expires_in. 
        # If expires_in is missing, default to 1 hour (3600s)
        expires_in = Map.get(response, "expires_in", 7200) # Default to 2 hours if missing? (standard is often 2hr or session length)

        attrs = %{
          token: response["access_token"],
          refresh_token: new_refresh_token,
          expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
        }

        # Also update instance_url if it changed (unlikely but possible)
        attrs = 
          if instance_url = response["instance_url"] do
             new_meta = Map.put(credential.meta || %{}, "instance_url", instance_url)
             Map.put(attrs, :meta, new_meta)
          else
             attrs
          end

        Accounts.update_user_credential(credential, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ensures a credential has a valid (non-expired) token.
  Refreshes if expired or about to expire (within 5 minutes).
  """
  def ensure_valid_token(credential) do
    buffer_seconds = 300

    if DateTime.compare(
         credential.expires_at,
         DateTime.add(DateTime.utc_now(), buffer_seconds, :second)
       ) == :lt do
      refresh_credential(credential)
    else
      {:ok, credential}
    end
  end
end
