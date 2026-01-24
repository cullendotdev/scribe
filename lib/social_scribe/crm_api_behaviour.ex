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

  @callback display_properties() :: %{
              color: String.t(),
              initial: String.t(),
              label: String.t()
            }
end
