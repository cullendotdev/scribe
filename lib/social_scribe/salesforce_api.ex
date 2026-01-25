defmodule SocialScribe.SalesforceApi do
  @moduledoc """
  Salesforce CRM API client for contacts operations.
  Implements automatic token refresh on 401/expired token errors.
  """

  use SocialScribe.Crm.ApiMacros, provider: "salesforce"

  @api_version "v60.0"

  # Get contact fields from Config
  @contact_fields Config.api_fields("salesforce")

  defp client(instance_url, access_token), do: BaseApi.client(instance_url, access_token)

  @doc """
  Searches for contacts using SOSL.
  """
  @impl SocialScribe.CrmApiBehaviour
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    BaseApi.with_token_refresh(credential, fn cred ->
      # recalculate instance url in case it changed (though rare for existing creds)
      instance_url = get_instance_url(cred)
      sanitized_query = String.replace(query, "{", "") |> String.replace("}", "")
      # Add wildcard for partial matching if query is long enough
      search_term =
        if String.length(sanitized_query) > 0, do: "#{sanitized_query}*", else: sanitized_query

      fields = Enum.join(@contact_fields, ", ")
      Logger.debug("Using Salesforce fields: #{fields}")

      sosl =
        "FIND {#{search_term}} IN ALL FIELDS RETURNING Contact(#{fields}) LIMIT 10"

      params = [q: sosl]

      case Tesla.get(client(instance_url, cred.token), "/services/data/#{@api_version}/search/",
             query: params
           ) do
        {:ok, %Tesla.Env{status: 200, body: %{"searchRecords" => records}}} ->
          contacts = Enum.map(records, &format_contact/1)
          {:ok, contacts}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Gets a single contact by ID.
  """
  @impl SocialScribe.CrmApiBehaviour
  def get_contact(%UserCredential{} = credential, contact_id) do
    BaseApi.with_token_refresh(credential, fn cred ->
      instance_url = get_instance_url(cred)

      fields = Enum.join(@contact_fields, ", ")
      soql = "SELECT #{fields} FROM Contact WHERE Id = '#{contact_id}'"
      params = [q: soql]

      case Tesla.get(client(instance_url, cred.token), "/services/data/#{@api_version}/query/",
             query: params
           ) do
        {:ok, %Tesla.Env{status: 200, body: %{"records" => [record | _]}}} ->
          {:ok, format_contact(record)}

        {:ok, %Tesla.Env{status: 200, body: %{"records" => []}}} ->
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
      instance_url = get_instance_url(cred)

      url = "/services/data/#{@api_version}/sobjects/Contact/#{contact_id}"

      case Tesla.patch(client(instance_url, cred.token), url, updates) do
        {:ok, %Tesla.Env{status: 204}} ->
          # 204 No Content means success
          get_contact(cred, contact_id)

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  defp get_instance_url(credential) do
    # Fallback, though likely wrong if missing
    credential.meta["instance_url"] || "https://login.salesforce.com"
  end

  # Format a Salesforce contact response using the shared ContactFormatter
  defp format_contact(record) do
    ContactFormatter.build_contact("salesforce", record["Id"], record)
  end
end
