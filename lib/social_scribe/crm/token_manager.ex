defmodule SocialScribe.Crm.TokenManager do
  @moduledoc """
  Unified service for managing and refreshing CRM OAuth tokens.
  """
  alias SocialScribe.Accounts
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Crm.Config

  require Logger

  @doc """
  Ensures a credential has a valid (non-expired) token.
  Refreshes if expired or about to expire based on provider-specific buffer.
  """
  def ensure_valid_token(%UserCredential{provider: provider} = credential) do
    config = Config.get(provider)
    buffer = config.token_expiry_buffer_seconds || 300

    if DateTime.compare(
         credential.expires_at,
         DateTime.add(DateTime.utc_now(), buffer, :second)
       ) == :lt do
      refresh_credential(credential)
    else
      {:ok, credential}
    end
  end

  @doc """
  Refreshes the token for a credential and updates it in the database.
  """
  def refresh_credential(%UserCredential{provider: provider} = credential) do
    config = Config.get(provider)

    case refresh_token(credential, config) do
      {:ok, response} ->
        attrs = format_refresh_attrs(provider, response, credential)
        Accounts.update_user_credential(credential, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers for provider-specific OAuth flows

  defp refresh_token(credential, config) do
    oauth_config = Application.get_env(:ueberauth, config.oauth_strategy, [])

    body = %{
      grant_type: "refresh_token",
      client_id: oauth_config[:client_id],
      client_secret: oauth_config[:client_secret],
      refresh_token: credential.refresh_token
    }

    client =
      Tesla.client([
        {Tesla.Middleware.FormUrlencoded,
         encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
        Tesla.Middleware.JSON
      ])

    case Tesla.post(client, config.token_url, body) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_refresh_attrs("hubspot", response, _credential) do
    %{
      token: response["access_token"],
      refresh_token: response["refresh_token"],
      expires_at: DateTime.add(DateTime.utc_now(), response["expires_in"], :second)
    }
  end

  defp format_refresh_attrs("salesforce", response, credential) do
    new_refresh_token = response["refresh_token"] || credential.refresh_token
    expires_in = Map.get(response, "expires_in", 7200)

    attrs = %{
      token: response["access_token"],
      refresh_token: new_refresh_token,
      expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
    }

    # Update instance_url in meta if provided
    if instance_url = response["instance_url"] do
      new_meta = Map.put(credential.meta || %{}, "instance_url", instance_url)
      Map.put(attrs, :meta, new_meta)
    else
      attrs
    end
  end

  defp format_refresh_attrs(_, response, _) do
    %{
      token: response["access_token"],
      refresh_token: response["refresh_token"],
      expires_at: DateTime.add(DateTime.utc_now(), Map.get(response, "expires_in", 3600), :second)
    }
  end
end
