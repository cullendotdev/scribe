defmodule SocialScribe.HubspotApi do
  @moduledoc """
  HubSpot CRM API client for contacts operations.
  Implements automatic token refresh on 401/expired token errors.
  """

  @behaviour SocialScribe.CrmApiBehaviour

  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Crm.BaseApi

  @impl SocialScribe.CrmApiBehaviour
  def display_properties do
    SocialScribe.Crm.Config.get("hubspot")
  end

  @base_url "https://api.hubapi.com"

  @contact_properties [
    "firstname",
    "lastname",
    "email",
    "phone",
    "mobilephone",
    "company",
    "jobtitle",
    "address",
    "city",
    "state",
    "zip",
    "country",
    "website",
    "hs_linkedin_url",
    "twitterhandle"
  ]

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

  # Format a HubSpot contact response into a cleaner structure
  defp format_contact(%{"id" => id, "properties" => properties}) do
    %{
      id: id,
      firstname: properties["firstname"],
      lastname: properties["lastname"],
      email: properties["email"],
      phone: properties["phone"],
      mobilephone: properties["mobilephone"],
      company: properties["company"],
      jobtitle: properties["jobtitle"],
      address: properties["address"],
      city: properties["city"],
      state: properties["state"],
      zip: properties["zip"],
      country: properties["country"],
      website: properties["website"],
      linkedin_url: properties["hs_linkedin_url"],
      twitter_handle: properties["twitterhandle"],
      provider: "hubspot",
      display_name: format_display_name(properties)
    }
  end

  defp format_contact(_), do: nil

  defp format_display_name(properties) do
    firstname = properties["firstname"] || ""
    lastname = properties["lastname"] || ""
    email = properties["email"] || ""

    name = String.trim("#{firstname} #{lastname}")

    if name == "" do
      email
    else
      name
    end
  end
end
