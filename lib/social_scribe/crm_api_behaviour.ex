defmodule SocialScribe.CrmApiBehaviour do
  @moduledoc """
  Standard behaviour for all CRM integrations.
  """

  alias SocialScribe.Accounts.UserCredential

  @callback search_contacts(credential :: UserCredential.t(), query :: String.t()) ::
              {:ok, list(map())} | {:error, any()}

  @callback get_contact(credential :: UserCredential.t(), contact_id :: String.t()) ::
              {:ok, map()} | {:error, any()}

  @callback update_contact(
              credential :: UserCredential.t(),
              contact_id :: String.t(),
              updates :: map()
            ) ::
              {:ok, map() | :ok | nil} | {:error, any()}

  @callback apply_updates(
              credential :: UserCredential.t(),
              contact_id :: String.t(),
              updates_list :: list(map())
            ) ::
              {:ok, map() | :no_updates} | {:error, any()}

  @callback display_properties() :: %{
              color: String.t(),
              initial: String.t(),
              label: String.t()
            }

  def search_contacts(%{provider: provider} = credential, query) do
    impl(provider).search_contacts(credential, query)
  end

  def get_contact(%{provider: provider} = credential, contact_id) do
    impl(provider).get_contact(credential, contact_id)
  end

  def update_contact(%{provider: provider} = credential, contact_id, updates) do
    impl(provider).update_contact(credential, contact_id, updates)
  end

  def apply_updates(%{provider: provider} = credential, contact_id, updates_list) do
    impl(provider).apply_updates(credential, contact_id, updates_list)
  end

  defp impl("hubspot") do
    Application.get_env(:social_scribe, :hubspot_api, SocialScribe.HubspotApi)
  end

  defp impl("salesforce") do
    Application.get_env(:social_scribe, :salesforce_api, SocialScribe.SalesforceApi)
  end
end
