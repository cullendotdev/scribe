defmodule SocialScribe.CrmApiBehaviour do
  @moduledoc """
  Standard behaviour for all CRM integrations.
  """

  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Crm.Config

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

  @callback get_contact_notes(credential :: UserCredential.t(), contact_id :: String.t()) ::
              {:ok, list(map())} | {:error, any()}

  @callback display_properties() :: %{
              color: String.t(),
              initial: String.t(),
              label: String.t()
            }

  def search_contacts(%{provider: provider} = credential, query) do
    Config.api_impl(provider).search_contacts(credential, query)
  end

  def get_contact(%{provider: provider} = credential, contact_id) do
    Config.api_impl(provider).get_contact(credential, contact_id)
  end

  def update_contact(%{provider: provider} = credential, contact_id, updates) do
    Config.api_impl(provider).update_contact(credential, contact_id, updates)
  end

  def apply_updates(%{provider: provider} = credential, contact_id, updates_list) do
    Config.api_impl(provider).apply_updates(credential, contact_id, updates_list)
  end

  def get_contact_notes(%{provider: provider} = credential, contact_id) do
    Config.api_impl(provider).get_contact_notes(credential, contact_id)
  end
end
