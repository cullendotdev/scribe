defmodule SocialScribeWeb.AuthController do
  use SocialScribeWeb, :controller

  alias SocialScribe.FacebookApi
  alias SocialScribe.Accounts
  alias SocialScribeWeb.UserAuth
  alias Ueberauth.Strategy.Helpers
  plug Ueberauth

  require Logger

  @doc """
  Handles the initial request to the provider (e.g., Google).
  Ueberauth's plug will redirect the user to the provider's consent page.
  """
  def request(conn, _params) do
    render(conn, "request.html", callback_url: Helpers.callback_url(conn))
  end

  @doc """
  Handles the callback from the provider.
  - Handles failure.
  - Handles linking accounts (User is logged in).
  - Handles login (User is not logged in).
  """
  def callback(%{assigns: %{ueberauth_failure: fails}} = conn, _params) do
    Logger.error("Failed to authenticate: #{inspect(fails)}")

    conn
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: "/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "google"
      })
      when not is_nil(user) do
    Logger.info("Google OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Google account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Google account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "linkedin"
      }) do
    Logger.info("LinkedIn OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        Logger.info("credential")
        Logger.info(credential)

        conn
        |> put_flash(:info, "LinkedIn account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error(reason)

        conn
        |> put_flash(:error, "Could not add LinkedIn account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "facebook"
      })
      when not is_nil(user) do
    Logger.info("Facebook OAuth")
    Logger.info(auth)

    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        case FacebookApi.fetch_user_pages(credential.uid, credential.token) do
          {:ok, facebook_pages} ->
            facebook_pages
            |> Enum.each(fn page ->
              Accounts.link_facebook_page(user, credential, page)
            end)

          _ ->
            :ok
        end

        conn
        |> put_flash(
          :info,
          "Facebook account added successfully. Please select a page to connect."
        )
        |> redirect(to: ~p"/dashboard/settings/facebook_pages")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Facebook account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "hubspot"
      })
      when not is_nil(user) do
    Logger.info("HubSpot OAuth")
    Logger.info(inspect(auth))

    hub_id = to_string(auth.uid)

    expiration =
      if auth.credentials.expires_at do
        DateTime.from_unix!(auth.credentials.expires_at)
      else
        # HubSpot access tokens allow for 30 minutes (1800 seconds) of validity. This change was implemented on Jan 13, 2026.
        # See: https://developers.hubspot.com/blog/oauth-token-management-hubspot-integrations
        DateTime.add(DateTime.utc_now(), 1800, :second)
      end

    attrs = %{
      user_id: user.id,
      provider: "hubspot",
      uid: hub_id,
      token: auth.credentials.token,
      refresh_token: auth.credentials.refresh_token,
      expires_at: expiration,
      email: auth.info.email,
      meta: %{}
    }

    case Accounts.find_or_create_hubspot_credential(user, attrs) do
      {:ok, _credential} ->
        Logger.info("HubSpot account connected for user #{user.id}, hub_id: #{hub_id}")

        conn
        |> put_flash(:info, "HubSpot account connected successfully!")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error("Failed to save HubSpot credential: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not connect HubSpot account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "salesforce"
      })
      when not is_nil(user) do
    Logger.info("Salesforce OAuth Link")

    expiration =
      if auth.credentials.expires_at do
        DateTime.from_unix!(auth.credentials.expires_at)
      else
        DateTime.add(DateTime.utc_now(), 7200, :second)
      end

    attrs = %{
      user_id: user.id,
      provider: "salesforce",
      uid: auth.uid,
      token: auth.credentials.token,
      refresh_token: auth.credentials.refresh_token,
      expires_at: expiration,
      email: auth.info.email,
      meta: %{
        "instance_url" => auth.extra.raw_info.token.other_params["instance_url"],
        "id" => auth.extra.raw_info.token.other_params["id"]
      }
    }

    case Accounts.find_or_create_salesforce_credential(user, attrs) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Salesforce account connected successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error("Failed to save Salesforce credential: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to connect Salesforce account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  # Fallback for linking providers when NOT logged in (if they shouldn't trigger login)
  # Salesforce and HubSpot are currently link-only.
  def callback(%{assigns: %{current_user: nil}} = conn, %{"provider" => "salesforce"}) do
    conn
    |> put_flash(:error, "You must be logged in to connect Salesforce.")
    |> redirect(to: "/")
  end

  def callback(%{assigns: %{current_user: nil}} = conn, %{"provider" => "hubspot"}) do
    conn
    |> put_flash(:error, "You must be logged in to connect HubSpot.")
    |> redirect(to: "/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    Logger.info("Google OAuth Login")
    Logger.info(auth)

    case Accounts.find_or_create_user_from_oauth(auth) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)

      {:error, reason} ->
        Logger.info("error")
        Logger.info(reason)

        conn
        |> put_flash(:error, "There was an error signing you in.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    Logger.error("OAuth Login")
    Logger.error(conn)

    conn
    |> put_flash(:error, "There was an error signing you in. Please try again.")
    |> redirect(to: ~p"/")
  end
end
