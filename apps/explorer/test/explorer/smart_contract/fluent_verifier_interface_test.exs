defmodule Explorer.SmartContract.FluentVerifierInterfaceTest do
  use ExUnit.Case, async: false

  alias Explorer.SmartContract.FluentVerifierInterface
  alias Plug.Conn

  describe "get_versions_list/0" do
    setup do
      bypass = Bypass.open()
      previous_config = Application.get_env(:explorer, Explorer.SmartContract.FluentVerifierInterface)

      Application.put_env(:explorer, Explorer.SmartContract.FluentVerifierInterface,
        service_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.SmartContract.FluentVerifierInterface, previous_config)
      end)

      {:ok, bypass: bypass}
    end

    test "uses GET /available-versions", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v1/fluent/available-versions", fn conn ->
        assert conn.query_string == "include_prerelease=false"
        Conn.resp(conn, 200, ~s({"versions":["v0.5.3","v0.5.2"]}))
      end)

      assert {:ok, ["v0.5.3", "v0.5.2"]} = FluentVerifierInterface.get_versions_list()
    end
  end
end
