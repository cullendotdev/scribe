defmodule SocialScribe.SalesforceApi do
  @moduledoc """
  Salesforce CRM API client for contacts operations.
  Implements automatic token refresh on 401/expired token errors.
  """

  @behaviour SocialScribe.CrmApiBehaviour

  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.SalesforceTokenRefresher

  require Logger

  @impl SocialScribe.CrmApiBehaviour
  def display_properties do
    %{
      color: "bg-[#00A1E0]",
      initial: "S",
      label: "Salesforce"
    }
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

  defp client(instance_url, access_token) do
    middleware = [
      {Tesla.Middleware.BaseUrl, instance_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{access_token}"},
         {"Content-Type", "application/json"}
       ]}
    ]

    Tesla.client(middleware)
  end

  @doc """
  Searches for contacts using SOSL.
  Returns up to 10 matching contacts.
  Automatically refreshes token on 401/expired errors.
  """
  @impl SocialScribe.CrmApiBehaviour
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    with_token_refresh(credential, fn cred ->
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
    with_token_refresh(credential, fn cred ->
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
  `updates` should be a map of property names to new values.
  """
  @impl SocialScribe.CrmApiBehaviour
  def update_contact(%UserCredential{} = credential, contact_id, updates)
      when is_map(updates) do
    with_token_refresh(credential, fn cred ->
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
  This is a convenience wrapper around update_contact/3.
  """
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

  # Wrapper that handles token refresh on auth errors
  defp with_token_refresh(%UserCredential{} = credential, api_call) do
    with {:ok, credential} <- SalesforceTokenRefresher.ensure_valid_token(credential) do
      try_api_call(credential, api_call)
    end
  end

  defp try_api_call(credential, api_call) do
    case api_call.(credential) do
      {:error, {:api_error, status, _body}} when status in [401, 403] ->
        # Salesforce session expired
        Logger.info("Salesforce token expired (status #{status}), refreshing...")
        retry_with_fresh_token(credential, api_call)

      other ->
        other
    end
  end

  defp retry_with_fresh_token(credential, api_call) do
    case SalesforceTokenRefresher.refresh_credential(credential) do
      {:ok, refreshed_credential} ->
        case api_call.(refreshed_credential) do
          {:error, {:api_error, status, body}} ->
            Logger.error("Salesforce API error after refresh: #{status} - #{inspect(body)}")
            {:error, {:api_error, status, body}}

          other ->
            other
        end

      {:error, refresh_error} ->
        Logger.error("Failed to refresh Salesforce token: #{inspect(refresh_error)}")
        {:error, {:token_refresh_failed, refresh_error}}
    end
  end
end
