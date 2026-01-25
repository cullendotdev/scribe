defmodule SocialScribe.Crm.BaseApi do
  @moduledoc """
  Shared logic and helpers for CRM API implementations.
  """
  require Logger
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Crm.TokenManager

  @doc """
  Builds a standard Tesla client with JSON and Auth headers.
  """
  def client(base_url, access_token) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, base_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{access_token}"},
         {"Content-Type", "application/json"}
       ]}
    ])
  end

  @doc """
  Wraps an API call with automatic token refresh logic.
  If the call fails with a 401 (Unauthorized), it attempts to refresh the token and retries.
  """
  def with_token_refresh(%UserCredential{} = credential, api_call) do
    with {:ok, credential} <- TokenManager.ensure_valid_token(credential) do
      case api_call.(credential) do
        {:error, {:api_error, status, body}} ->
          if is_token_error?(credential.provider, status, body) do
            Logger.info(
              "#{String.capitalize(credential.provider)} token expired (status #{status}), refreshing and retrying..."
            )

            retry_with_fresh_token(credential, api_call)
          else
            {:error, {:api_error, status, body}}
          end

        other ->
          other
      end
    end
  end

  defp retry_with_fresh_token(credential, api_call) do
    case TokenManager.refresh_credential(credential) do
      {:ok, refreshed_credential} ->
        case api_call.(refreshed_credential) do
          {:error, {:api_error, status, body}} ->
            Logger.error(
              "#{String.capitalize(credential.provider)} API error after refresh: #{status} - #{inspect(body)}"
            )

            {:error, {:api_error, status, body}}

          {:error, {:http_error, reason}} ->
            Logger.error(
              "#{String.capitalize(credential.provider)} HTTP error after refresh: #{inspect(reason)}"
            )

            {:error, {:http_error, reason}}

          success ->
            success
        end

      {:error, refresh_error} ->
        Logger.error("Failed to refresh #{credential.provider} token: #{inspect(refresh_error)}")
        {:error, {:token_refresh_failed, refresh_error}}
    end
  end

  # Provider-specific token error detection
  defp is_token_error?("hubspot", status, body) when status in [401, 400] do
    case body do
      %{"status" => s} when s in ["BAD_CLIENT_ID", "UNAUTHORIZED"] ->
        true

      %{"message" => msg} when is_binary(msg) ->
        String.contains?(String.downcase(msg), ["token", "expired", "unauthorized", "client id"])

      _ ->
        false
    end
  end

  defp is_token_error?("salesforce", status, _body) when status in [401, 403], do: true
  defp is_token_error?(_, _, _), do: false

  @doc """
  Shared implementation for batch updating contact properties.
  Filters to only apply updates marked with `apply: true`.
  Delegates the actual update to the provider-specific API module.
  """
  def apply_updates(api_module, credential, contact_id, updates_list)
      when is_list(updates_list) do
    updates_map =
      updates_list
      |> Enum.filter(fn update -> update[:apply] == true end)
      |> Enum.into(%{}, fn update -> {update.field, update.new_value} end)

    if map_size(updates_map) > 0 do
      api_module.update_contact(credential, contact_id, updates_map)
    else
      {:ok, :no_updates}
    end
  end
end
