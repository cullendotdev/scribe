defmodule Ueberauth.Strategy.Salesforce do
  @moduledoc """
  Salesforce Strategy for Üeberauth.
  """

  use Ueberauth.Strategy,
    uid_field: :user_id,
    default_scope: "api refresh_token offline_access",
    oauth2_module: Ueberauth.Strategy.Salesforce.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles the initial redirect to the salesforce authentication page.
  """

  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    # PKCE: Generate verifier and challenge
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    params =
      [scope: scopes]
      |> with_state_param(conn)
      |> Keyword.merge(option(conn, :extra_params) || [])
      |> Keyword.put(:response_type, "code")
      |> Keyword.put(:redirect_uri, callback_url(conn))
      |> Keyword.put(:code_challenge, challenge)
      |> Keyword.put(:code_challenge_method, "S256")

    opts = oauth_client_options_from_conn(conn)
    module = option(conn, :oauth2_module)

    # Store verifier in session for callback
    conn = Plug.Conn.put_session(conn, "salesforce_verifier", verifier)

    redirect!(conn, apply(module, :authorize_url!, [params, opts]))
  end

  @doc """
  Handles the callback from Salesforce.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    module = option(conn, :oauth2_module)
    opts = oauth_client_options_from_conn(conn)
    verifier = Plug.Conn.get_session(conn, "salesforce_verifier")

    require Logger
    Logger.info("Salesforce Callback: Code present. Verifier present: #{!is_nil(verifier)}")

    params = [
      code: code,
      redirect_uri: callback_url(conn),
      grant_type: "authorization_code",
      code_verifier: verifier
    ]

    # Cleanup session
    conn = Plug.Conn.delete_session(conn, "salesforce_verifier")

    case apply(module, :get_token!, [params, opts]) do
      {:error, %OAuth2.Response{body: %{"error" => reason}}} ->
        Logger.error("Salesforce OAuth Error (Response): #{inspect(reason)}")
        set_errors!(conn, [error("missing_code", reason)])

      {:error, %OAuth2.Error{reason: reason}} ->
        Logger.error("Salesforce OAuth Error (Error): #{inspect(reason)}")
        set_errors!(conn, [error("missing_code", reason)])

      %OAuth2.Client{token: %{access_token: nil} = _token} ->
        Logger.error("Salesforce OAuth Error: access_token is nil")
        set_errors!(conn, [
          error("token", "unauthorized")
        ])

      %OAuth2.Client{} = client ->
        Logger.info("Salesforce OAuth Success: Token received")
        fetch_user(conn, client)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:salesforce_user, nil)
    |> put_private(:salesforce_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    user =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.salesforce_user[user]
  end

  @doc """
  Includes the credentials from the salesforce response.
  """
  def credentials(conn) do
    token = conn.private.salesforce_token
    scopes = (token.other_params["scope"] || "") |> String.split(" ")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      token_type: token.token_type,
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.salesforce_user

    %Info{
      name: user["display_name"],
      nickname: user["nick_name"],
      email: user["email"],
      location: user["addr_city"],
      image: user["photos"]["picture"],
      urls: %{
        profile: user["profile"],
        enterprise: user["urls"]["enterprise"],
        metadata: user["urls"]["metadata"]
      }
    }
  end

  @doc """
  Stores the raw information (including the token) for use in the `Ueberauth.Auth` struct.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.salesforce_token,
        user: conn.private.salesforce_user
      }
    }
  end

  defp fetch_user(conn, client) do
    case OAuth2.Client.get(client, client.token.other_params["id"]) do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])

      {:ok, %OAuth2.Response{status_code: _status_code, body: user}} ->
        conn
        |> put_private(:salesforce_token, client.token)
        |> put_private(:salesforce_user, user)

      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("oauth2", reason)])
    end
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end

  defp oauth_client_options_from_conn(conn) do
    base_options = [header_serializer: Jason]
    request_options = Ueberauth.Strategy.Helpers.options(conn)

    case Keyword.get(request_options, :request_options) do
      nil -> base_options
      req_opts -> Keyword.merge(base_options, req_opts)
    end
  end
end
