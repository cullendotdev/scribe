defmodule SocialScribe.SalesforceApi do
  @moduledoc """
  Salesforce CRM API client for contacts operations.
  Implements automatic token refresh on 401/expired token errors.
  """

  @behaviour SocialScribe.CrmApiBehaviour

  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Crm.BaseApi

  require Logger

  @impl SocialScribe.CrmApiBehaviour
  def display_properties do
    SocialScribe.Crm.Config.get("salesforce")
  end

  @api_version "v60.0"

  # Standard Salesforce Contact fields to retrieve
  @contact_fields [
    "Id",
    "FirstName",
    "LastName",
    "Email",
    "Phone",
    "MobilePhone",
    "Account.Name",
    "Title",
    "MailingStreet",
    "MailingCity",
    "MailingState",
    "MailingPostalCode",
    "MailingCountry",
    "Department"
  ]

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

  @doc """
  Batch updates multiple properties on a contact.
  """
  @impl SocialScribe.CrmApiBehaviour
  def apply_updates(%UserCredential{} = credential, contact_id, updates_list)
      when is_list(updates_list) do
    updates_map =
      updates_list
      |> Enum.filter(fn update -> update[:apply] == true end)
      |> Enum.reduce(%{}, fn update, acc ->
        Map.put(acc, update.field, update.new_value)
      end)

    if map_size(updates_map) > 0 do
      update_contact(credential, contact_id, updates_map)
    else
      {:ok, :no_updates}
    end
  end

  defp get_instance_url(credential) do
    # Fallback, though likely wrong if missing
    credential.meta["instance_url"] || "https://login.salesforce.com"
  end

  # Format a Salesforce contact response into a cleaner structure matching HubspotApi
  defp format_contact(record) do
    %{
      id: record["Id"],
      firstname: record["FirstName"],
      lastname: record["LastName"],
      email: record["Email"],
      phone: record["Phone"],
      mobilephone: record["MobilePhone"],
      company: get_in(record, ["Account", "Name"]),
      jobtitle: record["Title"],
      address: record["MailingStreet"],
      city: record["MailingCity"],
      state: record["MailingState"],
      zip: record["MailingPostalCode"],
      country: record["MailingCountry"],
      department: record["Department"],
      provider: "salesforce",
      display_name: format_display_name(record)
    }
  end

  defp format_display_name(record) do
    firstname = record["FirstName"] || ""
    lastname = record["LastName"] || ""
    email = record["Email"] || ""

    name = String.trim("#{firstname} #{lastname}")

    if name == "" do
      email
    else
      name
    end
  end
end
