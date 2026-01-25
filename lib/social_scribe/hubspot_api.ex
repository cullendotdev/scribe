defmodule SocialScribe.HubspotApi do
  @moduledoc """
  HubSpot CRM API client for contacts operations.
  Implements automatic token refresh on 401/expired token errors.
  """

  use SocialScribe.Crm.ApiMacros, provider: "hubspot"

  @base_url "https://api.hubapi.com"

  # Get contact properties from Config
  @contact_properties Config.api_fields("hubspot")

  defp client(access_token), do: BaseApi.client(@base_url, access_token)

  @doc """
  Searches for contacts by query string.
  """
  @impl SocialScribe.CrmApiBehaviour
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    BaseApi.with_token_refresh(credential, fn cred ->
      body = %{
        query: query,
        limit: 10,
        properties: @contact_properties
      }

      case Tesla.post(client(cred.token), "/crm/v3/objects/contacts/search", body) do
        {:ok, %Tesla.Env{status: 200, body: %{"results" => results}}} ->
          contacts = Enum.map(results, &format_contact/1)
          {:ok, contacts}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Gets a single contact by ID with all properties.
  """
  @impl SocialScribe.CrmApiBehaviour
  def get_contact(%UserCredential{} = credential, contact_id) do
    BaseApi.with_token_refresh(credential, fn cred ->
      properties_param = Enum.join(@contact_properties, ",")
      url = "/crm/v3/objects/contacts/#{contact_id}?properties=#{properties_param}"

      case Tesla.get(client(cred.token), url) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          {:ok, format_contact(body)}

        {:ok, %Tesla.Env{status: 404, body: _body}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Updates a contact's properties.
  """
  @impl SocialScribe.CrmApiBehaviour
  def update_contact(%UserCredential{} = credential, contact_id, updates)
      when is_map(updates) do
    BaseApi.with_token_refresh(credential, fn cred ->
      body = %{properties: updates}

      case Tesla.patch(client(cred.token), "/crm/v3/objects/contacts/#{contact_id}", body) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          {:ok, format_contact(body)}

        {:ok, %Tesla.Env{status: 404, body: _body}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  # Format a HubSpot contact response using the shared ContactFormatter
  defp format_contact(%{"id" => id, "properties" => properties}) do
    ContactFormatter.build_contact("hubspot", id, properties)
  end

  defp format_contact(_), do: nil
end
