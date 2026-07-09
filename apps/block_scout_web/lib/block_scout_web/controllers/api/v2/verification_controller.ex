defmodule BlockScoutWeb.API.V2.VerificationController do
  use BlockScoutWeb, :controller
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  import Explorer.Helper, only: [parse_boolean: 1]

  require Logger

  alias BlockScoutWeb.AccessHelper
  alias BlockScoutWeb.API.V2.ApiView
  alias Explorer.Chain
  alias Explorer.Chain.SmartContract
  alias Explorer.SmartContract.{CompilerVersion, RustVerifierInterface, Solidity.CodeCompiler, StylusVerifierInterface}
  alias Explorer.SmartContract.Solidity.PublisherWorker, as: SolidityPublisherWorker
  alias Explorer.SmartContract.Solidity.PublishHelper
  alias Explorer.SmartContract.Stylus.PublisherWorker, as: StylusPublisherWorker
  alias Explorer.SmartContract.Vyper.PublisherWorker, as: VyperPublisherWorker
  alias Explorer.SmartContract.Fluent.PublisherWorker, as: FluentPublisherWorker
  alias Indexer.Fetcher.OnDemand.ContractCode

  alias Explorer.SmartContract.{
    CompilerVersion,
    RustVerifierInterface,
    Solidity.CodeCompiler,
    StylusVerifierInterface,
    FluentVerifierInterface
  }

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  @api_true [api?: true]
  @sc_verification_started "Smart-contract verification started"
  @zk_optimization_modes ["0", "1", "2", "3", "s", "z"]

  if @chain_type == :zksync do
    @optimization_runs "0"
  else
    @optimization_runs 200
  end

  def config(conn, _params) do
    solidity_compiler_versions = CompilerVersion.fetch_version_list(:solc)
    vyper_compiler_versions = CompilerVersion.fetch_version_list(:vyper)

    verification_options = get_verification_options()

    base_config = %{
      solidity_evm_versions: CodeCompiler.evm_versions(:solidity),
      solidity_compiler_versions: solidity_compiler_versions,
      vyper_compiler_versions: vyper_compiler_versions,
      verification_options: verification_options,
      vyper_evm_versions: CodeCompiler.evm_versions(:vyper),
      is_rust_verifier_microservice_enabled: RustVerifierInterface.enabled?(),
      license_types: Enum.into(SmartContract.license_types_enum(), %{})
    }

    config =
      base_config
      |> maybe_add_zk_options()
      |> maybe_add_stylus_options()
      |> maybe_add_fluent_options()

    conn
    |> json(config)
  end

  defp get_verification_options do
    if Application.get_env(:explorer, :chain_type) == :zksync do
      ["standard-input"]
    else
      ["flattened-code", "standard-input", "vyper-code"]
      |> (&if(Application.get_env(:explorer, Explorer.ThirdPartyIntegrations.Sourcify)[:enabled],
            do: ["sourcify" | &1],
            else: &1
          )).()
      |> (&if(RustVerifierInterface.enabled?(),
            do: ["multi-part", "vyper-multi-part", "vyper-standard-input"] ++ &1,
            else: &1
          )).()
      |> (&if(StylusVerifierInterface.enabled?(),
            do: ["stylus-github-repository" | &1],
            else: &1
          )).()
      |> (&if(FluentVerifierInterface.enabled?(),
            do: ["fluent" | &1],
            else: &1
          )).()
    end
  end

  defp maybe_add_zk_options(config) do
    if Application.get_env(:explorer, :chain_type) == :zksync do
      zk_compiler_versions = CompilerVersion.fetch_version_list(:zk)

      config
      |> Map.put(:zk_compiler_versions, zk_compiler_versions)
      |> Map.put(:zk_optimization_modes, @zk_optimization_modes)
    else
      config
    end
  end

  # Adds Stylus compiler versions to config if Stylus verification is enabled
  defp maybe_add_stylus_options(config) do
    if StylusVerifierInterface.enabled?() do
      config
      |> Map.put(:stylus_compiler_versions, CompilerVersion.fetch_version_list(:stylus))
    else
      config
    end
  end

  # Adds Fluent compiler versions to config if Fluent verification is enabled
  defp maybe_add_fluent_options(config) do
    if FluentVerifierInterface.enabled?() do
      config
      |> Map.put(:fluent_compiler_versions, CompilerVersion.fetch_version_list(:fluent))
    else
      config
    end
  end

  def verification_via_flattened_code(
        conn,
        %{"address_hash" => address_hash_string, "compiler_version" => compiler_version, "source_code" => source_code} =
          params
      ) do
    Logger.info("API v2 smart-contract #{address_hash_string} verification via flattened file")

    with :validated <- validate_address(conn, params) do
      verification_params =
        %{
          "address_hash" => String.downcase(address_hash_string),
          "compiler_version" => compiler_version,
          "contract_source_code" => source_code
        }
        |> Map.put("optimization", Map.get(params, "is_optimization_enabled", false))
        |> (&if(params |> Map.get("is_optimization_enabled", false) |> parse_boolean(),
              do: Map.put(&1, "optimization_runs", Map.get(params, "optimization_runs", @optimization_runs)),
              else: &1
            )).()
        |> Map.put("evm_version", Map.get(params, "evm_version", "default"))
        |> Map.put("autodetect_constructor_args", Map.get(params, "autodetect_constructor_args", true))
        |> Map.put("constructor_arguments", Map.get(params, "constructor_args", ""))
        |> Map.put("name", Map.get(params, "contract_name", ""))
        |> Map.put("external_libraries", Map.get(params, "libraries", %{}))
        |> Map.put("is_yul", Map.get(params, "is_yul_contract", false))
        |> Map.put("license_type", Map.get(params, "license_type"))

      log_sc_verification_started(address_hash_string)
      Que.add(SolidityPublisherWorker, {"flattened_api_v2", verification_params})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  def verification_via_standard_input(
        conn,
        %{"address_hash" => address_hash_string, "files" => _files, "compiler_version" => compiler_version} = params
      ) do
    Logger.info("API v2 smart-contract #{address_hash_string} verification via standard json input")

    with {:json_input, json_input} <- validate_params_standard_json_input(conn, params) do
      verification_params =
        %{
          "address_hash" => String.downcase(address_hash_string),
          "compiler_version" => compiler_version
        }
        |> Map.put("autodetect_constructor_args", Map.get(params, "autodetect_constructor_args", true))
        |> Map.put("constructor_arguments", Map.get(params, "constructor_args", ""))
        |> Map.put("name", Map.get(params, "contract_name", ""))
        |> Map.put("license_type", Map.get(params, "license_type"))
        |> (&if(Application.get_env(:explorer, :chain_type) == :zksync,
              do: Map.put(&1, "zk_compiler_version", Map.get(params, "zk_compiler_version")),
              else: &1
            )).()

      log_sc_verification_started(address_hash_string)
      Que.add(SolidityPublisherWorker, {"json_api_v2", verification_params, json_input})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  def verification_via_sourcify(conn, %{"address_hash" => address_hash_string, "files" => files} = params) do
    Logger.info("API v2 smart-contract #{address_hash_string} verification via Sourcify")

    with {:not_found, true} <-
           {:not_found, Application.get_env(:explorer, Explorer.ThirdPartyIntegrations.Sourcify)[:enabled]},
         :validated <- validate_address(conn, params),
         files_array <- PublishHelper.prepare_files_array(files),
         {:no_json_file, %Plug.Upload{path: _path}} <-
           {:no_json_file, PublishHelper.get_one_json(files_array)},
         files_content <- PublishHelper.read_files(files_array) do
      chosen_contract = params["chosen_contract_index"]

      log_sc_verification_started(address_hash_string)

      Que.add(
        SolidityPublisherWorker,
        {"sourcify_api_v2", String.downcase(address_hash_string), files_content, conn, chosen_contract}
      )

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  def verification_via_multi_part(
        conn,
        %{"address_hash" => address_hash_string, "compiler_version" => compiler_version, "files" => files} = params
      ) do
    Logger.info("API v2 smart-contract #{address_hash_string} verification via multipart")

    with :verifier_enabled <- check_microservice(),
         :validated <- validate_address(conn, params),
         libraries <- Map.get(params, "libraries", "{}"),
         {:libs_format, {:ok, json}} <- {:libs_format, Jason.decode(libraries)} do
      verification_params =
        %{
          "address_hash" => String.downcase(address_hash_string),
          "compiler_version" => compiler_version
        }
        |> Map.put("optimization", Map.get(params, "is_optimization_enabled", false))
        |> (&if(params |> Map.get("is_optimization_enabled", false) |> parse_boolean(),
              do: Map.put(&1, "optimization_runs", Map.get(params, "optimization_runs", @optimization_runs)),
              else: &1
            )).()
        |> Map.put("evm_version", Map.get(params, "evm_version", "default"))
        |> Map.put("external_libraries", json)
        |> Map.put("license_type", Map.get(params, "license_type"))

      files_array =
        files
        |> PublishHelper.prepare_files_array()
        |> PublishHelper.read_files()

      log_sc_verification_started(address_hash_string)
      Que.add(SolidityPublisherWorker, {"multipart_api_v2", verification_params, files_array})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  def verification_via_vyper_code(
        conn,
        %{"address_hash" => address_hash_string, "compiler_version" => compiler_version, "source_code" => source_code} =
          params
      ) do
    with :validated <- validate_address(conn, params) do
      verification_params =
        %{
          "address_hash" => String.downcase(address_hash_string),
          "compiler_version" => compiler_version,
          "contract_source_code" => source_code
        }
        |> Map.put("constructor_arguments", Map.get(params, "constructor_args", "") || "")
        |> Map.put("name", Map.get(params, "contract_name", "Vyper_contract"))
        |> Map.put("evm_version", Map.get(params, "evm_version"))
        |> Map.put("license_type", Map.get(params, "license_type"))

      log_sc_verification_started(address_hash_string)
      Que.add(VyperPublisherWorker, {"vyper_flattened", verification_params})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  def verification_via_vyper_multipart(
        conn,
        %{"address_hash" => address_hash_string, "compiler_version" => compiler_version, "files" => files} = params
      ) do
    Logger.info("API v2 vyper smart-contract #{address_hash_string} verification")

    with :verifier_enabled <- check_microservice(),
         :validated <- validate_address(conn, params) do
      interfaces = parse_interfaces(params["interfaces"])

      verification_params =
        %{
          "address_hash" => String.downcase(address_hash_string),
          "compiler_version" => compiler_version
        }
        |> Map.put("evm_version", Map.get(params, "evm_version"))
        |> Map.put("interfaces", interfaces)
        |> Map.put("license_type", Map.get(params, "license_type"))

      files_array =
        files
        |> PublishHelper.prepare_files_array()
        |> PublishHelper.read_files()

      log_sc_verification_started(address_hash_string)
      Que.add(VyperPublisherWorker, {"vyper_multipart", verification_params, files_array})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  def verification_via_vyper_standard_input(
        conn,
        %{"address_hash" => address_hash_string, "files" => _files, "compiler_version" => compiler_version} = params
      ) do
    Logger.info("API v2 vyper smart-contract #{address_hash_string} verification via standard json input")

    with :verifier_enabled <- check_microservice(),
         {:json_input, json_input} <- validate_params_standard_json_input(conn, params) do
      verification_params = %{
        "address_hash" => String.downcase(address_hash_string),
        "compiler_version" => compiler_version,
        "input" => json_input,
        "license_type" => Map.get(params, "license_type")
      }

      log_sc_verification_started(address_hash_string)
      Que.add(VyperPublisherWorker, {"vyper_standard_json", verification_params})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  @doc """
    Initiates verification of a Stylus smart contract using its GitHub repository source code.

    Validates the request parameters and queues the verification job to be processed
    asynchronously by the Stylus publisher worker.

    ## Parameters
    - `conn`: The connection struct
    - `params`: A map containing:
      - `address_hash`: Contract address to verify
      - `cargo_stylus_version`: Version of cargo-stylus used for deployment
      - `repository_url`: GitHub repository URL containing contract code
      - `commit`: Git commit hash used for deployment
      - `path_prefix`: Optional path prefix if contract is not in repository root

    ## Returns
    - JSON response with:
      - Success message if verification request is queued successfully
      - Error message if:
        - Stylus verification is not enabled
        - Address format is invalid
        - Contract is already verified
        - Access is restricted
  """
  @spec verification_via_stylus_github_repository(Plug.Conn.t(), %{String.t() => any()}) ::
          {:already_verified, true}
          | {:format, :error}
          | {:not_found, false | nil}
          | {:restricted_access, true}
          | Plug.Conn.t()
  def verification_via_stylus_github_repository(
        conn,
        %{
          "address_hash" => address_hash_string,
          "cargo_stylus_version" => _,
          "repository_url" => _,
          "commit" => _,
          "path_prefix" => _
        } = params
      ) do
    Logger.info("API v2 stylus smart-contract #{address_hash_string} verification via github repository")

    with {:not_found, true} <- {:not_found, StylusVerifierInterface.enabled?()},
         :validated <- validate_address(conn, params) do
      log_sc_verification_started(address_hash_string)
      Que.add(StylusPublisherWorker, {"github_repository", params})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  @doc """
  Initiates verification of a Fluent smart contract.

  This function handles verification for Fluent contracts from both Git
  repositories and source code archives. It validates the unified request
  payload and queues a single job type to be processed asynchronously by the
  `FluentPublisherWorker`.

  ## Parameters
  - `conn`: The connection struct.
  - `params`: A map containing the full verification payload:
    - `address_hash`: Contract address to verify.
    - `contract_name`: The name of the contract.
    - `abi`: The contract's ABI.
    - `compile_settings`: Compilation settings.
    - `git_source` (optional): Git source details.
    - `archive_source` (optional): Archive source details.

  ## Returns
  - A JSON response indicating that the verification has started, or an error.
  """
  @spec verification_via_fluent(Plug.Conn.t(), %{String.t() => any()}) :: Plug.Conn.t()
  def verification_via_fluent(
        conn,
        %{
          "address_hash" => address_hash_string,
          "contract_name" => _,
          "abi" => _,
          "compile_settings" => _
        } = params
      ) do
    Logger.info("API v2: Fluent smart-contract #{address_hash_string} verification request received.")

    with {:not_found, true} <- {:not_found, FluentVerifierInterface.enabled?()},
         :validated <- validate_address(conn, params, allow_changed_bytecode?: true),
         # Validate Fluent payload against the current HTTP schema
         :fluent_request_validated <- validate_fluent_request(params) do
      # All checks passed, queue the unified job
      log_sc_verification_started(address_hash_string)
      Que.add(FluentPublisherWorker, {"fluent", params})

      conn
      |> put_view(ApiView)
      |> render(:message, %{message: @sc_verification_started})
    end
  end

  # The old functions are now removed.
  # def verification_via_fluent_github_repository(conn, params) ...
  # def verification_via_fluent_archive(conn, params) ...

  # Validation helpers specific to Fluent verification requests.
  defp validate_fluent_request(params) do
    with :source_validated <- validate_fluent_source(params),
         :compile_settings_validated <- validate_fluent_compile_settings(params["compile_settings"]) do
      :fluent_request_validated
    end
  end

  defp validate_fluent_source(params) do
    git_source = Map.get(params, "git_source")
    archive_source = Map.get(params, "archive_source")

    case {is_map(git_source), is_map(archive_source)} do
      {true, false} -> validate_fluent_git_source(git_source)
      {false, true} -> validate_fluent_archive_source(archive_source)
      {true, true} -> {:error, "Request must contain either 'git_source' or 'archive_source', but not both."}
      {false, false} -> {:error, "Request must contain either 'git_source' or 'archive_source'."}
    end
  end

  defp validate_fluent_git_source(git_source) do
    repository_url = git_source["repository_url"]
    commit_ref = git_source["commit_ref"] || git_source["commit_reference"] || git_source["commit"]

    cond do
      !is_binary(repository_url) or repository_url == "" ->
        {:error, "git_source.repository_url is required"}

      !is_binary(commit_ref) or commit_ref == "" ->
        {:error, "git_source.commit_ref is required"}

      true ->
        :source_validated
    end
  end

  defp validate_fluent_archive_source(archive_source) do
    content = archive_source["content"]

    if is_binary(content) and content != "" do
      :source_validated
    else
      {:error, "archive_source.content is required"}
    end
  end

  defp validate_fluent_compile_settings(settings) when is_map(settings) do
    sdk_version = settings["sdk_version"]

    cond do
      !is_binary(sdk_version) or sdk_version == "" ->
        {:error, "compile_settings.sdk_version is required"}

      Map.has_key?(settings, "features") and !is_list(settings["features"]) ->
        {:error, "compile_settings.features must be an array of strings"}

      Map.has_key?(settings, "rust_flags") and !is_list(settings["rust_flags"]) ->
        {:error, "compile_settings.rust_flags must be an array of strings"}

      Map.has_key?(settings, "no_default_features") and !is_boolean(settings["no_default_features"]) ->
        {:error, "compile_settings.no_default_features must be a boolean"}

      Map.has_key?(settings, "rust_toolchain") and
        !is_binary(settings["rust_toolchain"]) and
          !is_nil(settings["rust_toolchain"]) ->
        {:error, "compile_settings.rust_toolchain must be a string"}

      Map.has_key?(settings, "manifest_path") and
        !is_binary(settings["manifest_path"]) and
          !is_nil(settings["manifest_path"]) ->
        {:error, "compile_settings.manifest_path must be a string"}

      true ->
        :compile_settings_validated
    end
  end

  defp validate_fluent_compile_settings(_), do: {:error, "compile_settings must be an object"}

  defp parse_interfaces(interfaces) do
    cond do
      is_binary(interfaces) ->
        case Jason.decode(interfaces) do
          {:ok, map} ->
            map

          _ ->
            nil
        end

      is_map(interfaces) ->
        interfaces
        |> PublishHelper.prepare_files_array()
        |> PublishHelper.read_files()

      true ->
        nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp validate_params_standard_json_input(conn, %{"files" => files} = params) do
    with :validated <- validate_address(conn, params),
         files_array <- PublishHelper.prepare_files_array(files),
         {:no_json_file, %Plug.Upload{path: path}} <-
           {:no_json_file, PublishHelper.get_one_json(files_array)},
         {:file_error, {:ok, json_input}} <- {:file_error, File.read(path)} do
      {:json_input, json_input}
    end
  end

  defp validate_address(conn, %{"address_hash" => address_hash_string} = params, options \\ []) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:not_a_smart_contract, {:ok, _bytecode}} <-
           {:not_a_smart_contract,
            conn
            |> AccessHelper.conn_to_ip_string()
            |> ContractCode.get_or_fetch_bytecode(address_hash)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:already_verified, false} <- {:already_verified, already_verified?(address_hash, options)} do
      :validated
    end
  end

  defp already_verified?(address_hash, allow_changed_bytecode?: true) do
    case SmartContract.address_hash_to_smart_contract(address_hash, @api_true) do
      %SmartContract{partially_verified: false, is_changed_bytecode: false} -> true
      _ -> false
    end
  end

  defp already_verified?(address_hash, _options) do
    SmartContract.verified_with_full_match?(address_hash, @api_true)
  end

  defp check_microservice do
    with {:not_found, true} <- {:not_found, RustVerifierInterface.enabled?()} do
      :verifier_enabled
    end
  end

  defp log_sc_verification_started(address_hash_string) do
    Logger.info("API v2 smart-contract #{address_hash_string} verification request sent to the microservice")
  end
end
