defmodule Explorer.SmartContract.RustVerifierFallbackTest do
  use ExUnit.Case, async: false

  alias Explorer.SmartContract.{CompilerVersion, RustVerifierFallback, RustVerifierInterface}
  alias Plug.Conn

  @primary_key Explorer.SmartContract.RustVerifierInterfaceBehaviour
  @fallback_key Explorer.SmartContract.RustVerifierFallbackInterface

  @primary_versions ~s({"compilerVersions":["v0.8.36+commit.8a079791","v0.8.35+commit.b5e5f8b9"]})
  @fallback_versions ~s({"compilerVersions":["v0.8.37+commit.f401782d","v0.8.36+commit.8a079791"]})
  @primary_vyper_versions ~s({"compilerVersions":["v0.3.10+commit.91361694"]})

  @metadata %{"chainId" => "20993", "contractAddress" => "0xBe6A5F06EF416D5C49FE9a0bC827CdEe58007892"}

  setup do
    primary = Bypass.open()
    fallback = Bypass.open()

    previous_primary = Application.get_env(:explorer, @primary_key)
    previous_fallback = Application.get_env(:explorer, @fallback_key)

    Application.put_env(:explorer, @primary_key,
      service_url: "http://localhost:#{primary.port}",
      enabled: true,
      type: "eth_bytecode_db",
      eth_bytecode_db?: true,
      api_key: "primary-key"
    )

    Application.put_env(:explorer, @fallback_key,
      service_url: "http://localhost:#{fallback.port}",
      enabled: true
    )

    Application.put_env(:tesla, :adapter, Tesla.Adapter.Mint)

    on_exit(fn ->
      Application.put_env(:explorer, @primary_key, previous_primary)
      Application.put_env(:explorer, @fallback_key, previous_fallback)
      Application.put_env(:tesla, :adapter, Explorer.Mock.TeslaAdapter)
    end)

    {:ok, primary: primary, fallback: fallback}
  end

  describe "verify_multi_part/2" do
    test "posts to the primary verifier when the fallback is disabled", %{primary: primary} do
      Application.put_env(:explorer, @fallback_key, service_url: nil, enabled: false)

      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"POST", "/api/v2/verifier/solidity/sources:verify-multi-part"}
        Conn.resp(conn, 200, success("primary"))
      end)

      assert {:ok, %{"fileName" => "primary"}} =
               RustVerifierInterface.verify_multi_part(multi_part_body("v0.8.37+commit.f401782d"), @metadata)
    end

    test "posts to the primary verifier when it knows the compiler version", %{primary: primary} do
      Bypass.expect(primary, fn conn ->
        case route(conn) do
          {"GET", "/api/v2/verifier/solidity/versions"} ->
            Conn.resp(conn, 200, @primary_versions)

          {"POST", "/api/v2/verifier/solidity/sources:verify-multi-part"} ->
            assert {"x-api-key", "primary-key"} in conn.req_headers
            Conn.resp(conn, 200, success("primary"))
        end
      end)

      assert {:ok, %{"fileName" => "primary"}} =
               RustVerifierInterface.verify_multi_part(multi_part_body("v0.8.36+commit.8a079791"), @metadata)
    end

    test "posts to the fallback verifier when the primary does not know the compiler version", %{
      primary: primary,
      fallback: fallback
    } do
      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 200, @primary_versions)
      end)

      Bypass.expect_once(fallback, fn conn ->
        assert route(conn) == {"POST", "/api/v2/verifier/solidity/sources:verify-multi-part"}
        refute Enum.any?(conn.req_headers, fn {name, _} -> name == "x-api-key" end)

        {:ok, raw_body, conn} = Conn.read_body(conn)
        body = Jason.decode!(raw_body)
        assert body["compilerVersion"] == "v0.8.37+commit.f401782d"
        assert body["metadata"] == @metadata

        Conn.resp(conn, 200, success("fallback"))
      end)

      assert {:ok, %{"fileName" => "fallback"}} =
               RustVerifierInterface.verify_multi_part(multi_part_body("v0.8.37+commit.f401782d"), @metadata)
    end

    test "posts to the primary verifier when its version list is unavailable", %{primary: primary} do
      Bypass.expect(primary, fn conn ->
        case route(conn) do
          {"GET", "/api/v2/verifier/solidity/versions"} ->
            Conn.resp(conn, 500, "")

          {"POST", "/api/v2/verifier/solidity/sources:verify-multi-part"} ->
            Conn.resp(conn, 200, success("primary"))
        end
      end)

      assert {:ok, %{"fileName" => "primary"}} =
               RustVerifierInterface.verify_multi_part(multi_part_body("v0.8.37+commit.f401782d"), @metadata)
    end
  end

  describe "verify_standard_json_input/2" do
    test "posts to the fallback verifier when the primary does not know the compiler version", %{
      primary: primary,
      fallback: fallback
    } do
      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 200, @primary_versions)
      end)

      Bypass.expect_once(fallback, fn conn ->
        assert route(conn) == {"POST", "/api/v2/verifier/solidity/sources:verify-standard-json"}
        Conn.resp(conn, 200, success("fallback"))
      end)

      body = %{
        "bytecode" => "0x6080",
        "bytecodeType" => "CREATION_INPUT",
        "compilerVersion" => "v0.8.37+commit.f401782d",
        "input" => "{}"
      }

      assert {:ok, %{"fileName" => "fallback"}} = RustVerifierInterface.verify_standard_json_input(body, @metadata)
    end
  end

  describe "vyper_verify_multipart/2" do
    test "routes by the vyper version list", %{primary: primary, fallback: fallback} do
      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/vyper/versions"}
        Conn.resp(conn, 200, @primary_vyper_versions)
      end)

      Bypass.expect_once(fallback, fn conn ->
        assert route(conn) == {"POST", "/api/v2/verifier/vyper/sources:verify-multi-part"}
        Conn.resp(conn, 200, success("fallback"))
      end)

      body = %{
        "bytecode" => "0x6080",
        "bytecodeType" => "CREATION_INPUT",
        "compilerVersion" => "v0.4.0+commit.e9db8d9f",
        "sourceFiles" => %{"a.vy" => ""}
      }

      assert {:ok, %{"fileName" => "fallback"}} = RustVerifierInterface.vyper_verify_multipart(body, @metadata)
    end
  end

  describe "CompilerVersion.fetch_versions/1" do
    test "merges the fallback versions into the primary list, newest first", %{primary: primary, fallback: fallback} do
      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 200, @primary_versions)
      end)

      Bypass.expect_once(fallback, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 200, @fallback_versions)
      end)

      assert {:ok, ["v0.8.37+commit.f401782d", "v0.8.36+commit.8a079791", "v0.8.35+commit.b5e5f8b9"]} =
               CompilerVersion.fetch_versions(:solc)
    end

    test "returns the primary list alone when the fallback is disabled", %{primary: primary} do
      Application.put_env(:explorer, @fallback_key, service_url: nil, enabled: false)

      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 200, @primary_versions)
      end)

      assert {:ok, ["v0.8.36+commit.8a079791", "v0.8.35+commit.b5e5f8b9"]} = CompilerVersion.fetch_versions(:solc)
    end

    test "returns the primary list when the fallback list is unavailable", %{primary: primary, fallback: fallback} do
      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 200, @primary_versions)
      end)

      Bypass.expect_once(fallback, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/solidity/versions"}
        Conn.resp(conn, 503, "")
      end)

      assert {:ok, ["v0.8.36+commit.8a079791", "v0.8.35+commit.b5e5f8b9"]} = CompilerVersion.fetch_versions(:solc)
    end

    test "merges the vyper lists too", %{primary: primary, fallback: fallback} do
      Bypass.expect_once(primary, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/vyper/versions"}
        Conn.resp(conn, 200, @primary_vyper_versions)
      end)

      Bypass.expect_once(fallback, fn conn ->
        assert route(conn) == {"GET", "/api/v2/verifier/vyper/versions"}
        Conn.resp(conn, 200, ~s({"compilerVersions":["v0.4.0+commit.e9db8d9f"]}))
      end)

      assert {:ok, ["v0.4.0+commit.e9db8d9f", "v0.3.10+commit.91361694"]} = CompilerVersion.fetch_versions(:vyper)
    end
  end

  describe "merge_versions/2" do
    test "deduplicates and orders releases, prereleases and nightlies by version" do
      primary = ["v0.8.36+commit.8a079791", "v0.8.36-nightly.2026.1.5+commit.aaaaaaaa", "v0.4.26+commit.4563c3fc"]
      fallback = ["v0.8.37+commit.f401782d", "v0.8.37-pre.1+commit.bbbbbbbb", "v0.8.36+commit.8a079791"]

      assert RustVerifierFallback.merge_versions(primary, fallback) == [
               "v0.8.37+commit.f401782d",
               "v0.8.37-pre.1+commit.bbbbbbbb",
               "v0.8.36+commit.8a079791",
               "v0.8.36-nightly.2026.1.5+commit.aaaaaaaa",
               "v0.4.26+commit.4563c3fc"
             ]
    end

    test "keeps versions it cannot parse at the end" do
      assert RustVerifierFallback.merge_versions(["latest", "v0.8.36+commit.8a079791"], ["v0.8.37+commit.f401782d"]) ==
               ["v0.8.37+commit.f401782d", "v0.8.36+commit.8a079791", "latest"]
    end
  end

  # The interface percent-encodes the ":" in verifier paths; compare the decoded path.
  defp route(conn), do: {conn.method, URI.decode(conn.request_path)}

  defp multi_part_body(compiler_version) do
    %{
      "bytecode" => "0x6080",
      "bytecodeType" => "CREATION_INPUT",
      "compilerVersion" => compiler_version,
      "sourceFiles" => %{"a.sol" => "contract A {}"},
      "evmVersion" => "default",
      "optimizationRuns" => 200,
      "libraries" => %{}
    }
  end

  defp success(file_name) do
    ~s({"message":"OK","status":"SUCCESS","source":{"fileName":"#{file_name}"}})
  end
end
