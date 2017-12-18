defmodule Annon.Acceptance.Smoke.AclTest do
  @moduledoc false
  use Annon.AcceptanceCase, async: true

  setup do
    api_path = "/httpbin"
    api = :api
          |> build_factory_params(%{
      name: "An HTTPBin service endpoint",
      request: %{
        methods: ["GET", "POST"],
        scheme: "http",
        host: get_endpoint_host(:public),
        port: get_endpoint_port(:public),
        path: api_path,
      }
    })
          |> create_api()
          |> get_body()

    api_id = get_in(api, ["data", "id"])

    proxy_plugin = :proxy_plugin
                   |> build_factory_params(%{settings: %{
      scheme: "http",
      host: "httpbin.org",
      port: 80,
      path: "/get",
      strip_api_path: true
    }})

    "apis/#{api_id}/plugins/proxy"
    |> put_management_url()
    |> put!(%{"plugin" => proxy_plugin})
    |> assert_status(201)

    acl_plugin = :acl_plugin
                 |> build_factory_params(%{settings: %{
      rules: [
        %{methods: ["GET"], path: ".*", scopes: ["httpbin:read"]},
        %{methods: ["PUT", "POST", "DELETE"], path: ".*", scopes: ["httpbin:write"]},
      ]
    }})

    "apis/#{api_id}/plugins/acl"
    |> put_management_url()
    |> put!(%{"plugin" => acl_plugin})
    |> assert_status(201)

    auth_plugin = :auth_plugin_with_jwt
                  |> build_factory_params()

    secret = Base.decode64!(auth_plugin.settings["secret"])

    "apis/#{api_id}/plugins/auth"
    |> put_management_url()
    |> put!(%{"plugin" => auth_plugin})
    |> assert_status(201)

    %{api_path: api_path, secret: secret}
  end

  test "A request with incorrect auth header is forbidden to access upstream" do
    response =
      "/httpbin?my_param=my_value"
      |> put_public_url()
      |> HTTPoison.get!([{"authorization", "Bearer bad_token"}, magic_header()])
      |> Map.get(:body)
      |> Poison.decode!

    assert "JWT token is invalid" == response["error"]["message"]
    assert "access_denied" == response["error"]["type"]
    assert 401 == response["meta"]["code"]

    assert_logs_are_written(response)
  end

  test "A request with good auth header is allowed to access upstream", %{secret: secret} do
    auth_token = build_jwt_token(%{"consumer_id" => "id", "consumer_scope" => ["httpbin:read"]}, secret)

    response =
      "/httpbin?my_param=my_value"
      |> put_public_url()
      |> HTTPoison.get!([{"authorization", "Bearer #{auth_token}"}, magic_header()])
      |> Map.get(:body)
      |> Poison.decode!

    assert "my_value" == response["args"]["my_param"]

    assert_logs_are_written(response)
  end

  test "A valid access scope is required to access upstream", %{secret: secret} do
    auth_token = build_jwt_token(%{"consumer_id" => "id", "consumer_scope" => ["httpbin:read"]}, secret)
    headers = [
      {"authorization", "Bearer #{auth_token}"},
      {"content-type", "application/json"}
    ]

    response =
      "/httpbin?my_param=my_value"
      |> put_public_url()
      |> HTTPoison.post!(Poison.encode!(%{}), headers ++ [magic_header()])
      |> Map.get(:body)
      |> Poison.decode!

    msg = "Your scope does not allow to access this resource. Missing allowances: httpbin:write"
    assert msg == response["error"]["message"]
    assert "forbidden" == response["error"]["type"]
    assert 403 == response["meta"]["code"]

    assert_logs_are_written(response)
  end

  test "A valid broker scope is required to access upstream", %{secret: secret} do
    auth_token = build_jwt_token(%{
      "consumer_id" => "id",
      "consumer_scope" => ["httpbin:read, httpbin:write"],
      "broker_scope" => "httpbin:read"
    }, secret)

    headers = [
      {"authorization", "Bearer #{auth_token}"},
      {"content-type", "application/json"}
    ]

    response =
      "/httpbin?my_param=my_value"
      |> put_public_url()
      |> HTTPoison.post!(Poison.encode!(%{}), headers ++ [magic_header()])
      |> Map.get(:body)
      |> Poison.decode!

    assert "Scope is not allowed by broker" == response["error"]["message"]
    assert "forbidden" == response["error"]["type"]
    assert 403 == response["meta"]["code"]

    assert_logs_are_written(response)
  end

  test "Broker is disabled", %{secret: secret} do
    auth_token = build_jwt_token(%{
      "consumer_id" => "id",
      "consumer_scope" => ["httpbin:read"],
      "broker_scope" => ""
    }, secret)

    headers = [
      {"authorization", "Bearer #{auth_token}"},
      {"content-type", "application/json"}
    ]

    response =
      "/httpbin?my_param=my_value"
      |> put_public_url()
      |> HTTPoison.get!(headers ++ [magic_header()])
      |> Map.get(:body)
      |> Poison.decode!

    assert "Scope is not allowed by broker" == response["error"]["message"]
    assert "forbidden" == response["error"]["type"]
    assert 403 == response["meta"]["code"]

    assert_logs_are_written(response)
  end

  defp assert_logs_are_written(_response) do
    # TODO: make this rigth
    assert true
  end
end
