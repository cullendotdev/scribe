defmodule SocialScribe.Crm.ContactFormatter do
  @moduledoc """
  Shared contact formatting utilities for CRM integrations.
  Provides consistent contact structure across all providers.
  """

  @doc """
  Formats a display name from first/last name components, falling back to email.
  """
  def format_display_name(firstname, lastname, email \\ nil) do
    first = firstname || ""
    last = lastname || ""
    name = String.trim("#{first} #{last}")

    if name == "", do: email || "", else: name
  end

  @doc """
  Builds a standardized contact map from provider-specific raw data.
  The field_mapping should be a keyword list mapping internal keys to raw data keys.
  """
  def build_contact(provider, id, raw_data, opts \\ []) do
    field_mapping = Keyword.get(opts, :field_mapping, default_field_mapping(provider))
    extra_fields = Keyword.get(opts, :extra_fields, %{})

    base =
      field_mapping
      |> Enum.reduce(%{id: id, provider: provider}, fn {internal_key, raw_key}, acc ->
        value = get_nested_value(raw_data, raw_key)
        Map.put(acc, internal_key, value)
      end)

    # Add display_name
    display_name =
      format_display_name(
        base[:firstname],
        base[:lastname],
        base[:email]
      )

    base
    |> Map.put(:display_name, display_name)
    |> Map.merge(extra_fields)
  end

  # Handles nested keys like "Account.Name" for Salesforce
  defp get_nested_value(data, key) when is_binary(key) do
    if String.contains?(key, ".") do
      keys = String.split(key, ".")
      get_in(data, keys)
    else
      data[key]
    end
  end

  defp get_nested_value(data, keys) when is_list(keys) do
    get_in(data, keys)
  end

  # Default field mappings derived from Config
  defp default_field_mapping("hubspot") do
    [
      firstname: "firstname",
      lastname: "lastname",
      email: "email",
      phone: "phone",
      mobilephone: "mobilephone",
      company: "company",
      jobtitle: "jobtitle",
      address: "address",
      city: "city",
      state: "state",
      zip: "zip",
      country: "country",
      website: "website",
      linkedin_url: "hs_linkedin_url",
      twitter_handle: "twitterhandle"
    ]
  end

  defp default_field_mapping("salesforce") do
    [
      firstname: "FirstName",
      lastname: "LastName",
      email: "Email",
      phone: "Phone",
      mobilephone: "MobilePhone",
      company: "Account.Name",
      jobtitle: "Title",
      address: "MailingStreet",
      city: "MailingCity",
      state: "MailingState",
      zip: "MailingPostalCode",
      country: "MailingCountry",
      department: "Department"
    ]
  end

  defp default_field_mapping(_), do: []
end
