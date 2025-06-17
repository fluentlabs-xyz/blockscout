defmodule Explorer.SmartContract.Fluent.Publisher do
  @moduledoc """
  Module responsible for verifying and publishing Fluent smart contracts.

  The verification process includes:
  1. Initiating verification through a microservice that compares Git repository
     or archive source code against deployed WASM bytecode
  2. Processing the verification response, including ABI and source files
  3. Creating or updating the smart contract record in the database
  4. Handling verification failures by creating invalid changesets with error messages
  """

  require Logger

  alias Explorer.Chain.SmartContract
  alias Explorer.SmartContract.Fluent.Verifier
  alias Explorer.SmartContract.Helper

  @default_file_name "src/lib.rs"

  @sc_verification_via_git_repository_started "Smart-contract verification via Git repository started"
  @sc_verification_via_archive_started "Smart-contract verification via archive started"

  @doc """
  Verifies and publishes a Fluent smart contract using Git repository source code.

  ## Parameters
  - `address_hash`: The contract's address hash as binary or `t:Explorer.Chain.Hash.t/0`
  - `params`: Map containing verification parameters

  ## Returns
  - `{:ok, smart_contract}` if verification and database storage succeed
  - `{:error, changeset}` if verification fails or there are validation errors
  """
  @spec publish_git(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}) ::
          {:error, Ecto.Changeset.t()} | {:ok, Explorer.Chain.SmartContract.t()}
  def publish_git(address_hash, params) do
    Logger.info(@sc_verification_via_git_repository_started)

    case Verifier.evaluate_authenticity_git(address_hash, params) do
      {:ok, result_params} ->
        process_verifier_response(result_params, address_hash)

      {:error, error} ->
        handle_verification_error(address_hash, params, error, false)

      _ ->
        {:error, unverified_smart_contract(address_hash, params, "Unexpected error", nil)}
    end
  end

  @doc """
  Verifies and publishes a Fluent smart contract using source code archive.

  ## Parameters
  - `address_hash`: The contract's address hash as binary or `t:Explorer.Chain.Hash.t/0`
  - `params`: Map containing verification parameters

  ## Returns
  - `{:ok, smart_contract}` if verification and database storage succeed
  - `{:error, changeset}` if verification fails or there are validation errors
  """
  @spec publish_archive(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}) ::
          {:error, Ecto.Changeset.t()} | {:ok, Explorer.Chain.SmartContract.t()}
  def publish_archive(address_hash, params) do
    Logger.info(@sc_verification_via_archive_started)

    case Verifier.evaluate_authenticity_archive(address_hash, params) do
      {:ok, result_params} ->
        process_verifier_response(result_params, address_hash)

      {:error, error} ->
        handle_verification_error(address_hash, params, error, true)

      _ ->
        {:error, unverified_smart_contract(address_hash, params, "Unexpected error", nil, true)}
    end
  end

  # Process successful verification response
  defp process_verifier_response(
         %{
           "contract_name" => contract_name,
           "abi_json_string" => abi_string,
           "build_metadata" => build_metadata,
           "source_files" => source_files
         },
         address_hash
       ) do
    # Find main source file
    main_file_path = find_main_source_file(source_files)
    main_source_code = Map.get(source_files, main_file_path, "")

    # Prepare secondary sources
    secondary_sources = prepare_secondary_sources(source_files, main_file_path, address_hash)

    # Extract metadata
    compiler_version = get_compiler_version(build_metadata)
    package_name = get_package_name(build_metadata)

    prepared_params =
      %{}
      |> Map.put("compiler_version", compiler_version)
      |> Map.put("contract_source_code", main_source_code)
      |> Map.put("name", contract_name)
      |> Map.put("file_path", main_file_path)
      |> Map.put("secondary_sources", secondary_sources)
      |> Map.put("package_name", package_name)
      |> Map.put("fluent_metadata", build_metadata)

    publish_smart_contract(address_hash, prepared_params, Jason.decode!(abi_string || "null"))
  end

  # Handle verification errors
  defp handle_verification_error(address_hash, params, error, with_files?) do
    error_message = extract_error_message(error)
    {:error, unverified_smart_contract(address_hash, params, error, error_message, with_files?)}
  end

  # Extract error message from various error formats
  defp extract_error_message(%{"error_message" => msg}), do: msg
  defp extract_error_message(%{"errorMessage" => msg}), do: msg
  defp extract_error_message(%{"message" => msg}), do: msg
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(_), do: nil

  # Find the main source file
  defp find_main_source_file(source_files) when is_map(source_files) do
    # Priority order for main file
    candidate_paths = [@default_file_name, "lib.rs", "src/lib.rs", "main.rs", "src/main.rs"]

    Enum.find(candidate_paths, fn path ->
      Map.has_key?(source_files, path)
    end) || List.first(Map.keys(source_files)) || @default_file_name
  end

  defp find_main_source_file(_), do: @default_file_name

  # Prepare secondary sources
  defp prepare_secondary_sources(source_files, main_file_path, address_hash) when is_map(source_files) do
    source_files
    |> Enum.reject(fn {path, _content} -> path == main_file_path end)
    |> Enum.map(fn {path, content} ->
      %{
        "file_name" => path,
        "contract_source_code" => content,
        "address_hash" => address_hash
      }
    end)
  end

  defp prepare_secondary_sources(_, _, _), do: []

  # Extract compiler version from metadata
  defp get_compiler_version(build_metadata) do
    get_in(build_metadata, ["compiler", "version"]) || ""
  end

  # Extract package name from metadata
  defp get_package_name(build_metadata) do
    get_in(build_metadata, ["settings", "contract_info", "name"]) ||
    get_in(build_metadata, ["settings", "contractInfo", "name"]) ||
    ""
  end

  # Publish smart contract to database
  defp publish_smart_contract(address_hash, params, abi) do
    attrs = attributes(address_hash, params, abi)

    ok_or_error = SmartContract.create_or_update_smart_contract(address_hash, attrs, false)

    case ok_or_error do
      {:ok, _} ->
        Logger.info("Fluent smart-contract #{address_hash} successfully published")

      {:error, error} ->
        Logger.error("Fluent smart-contract #{address_hash} failed to publish: #{inspect(error)}")
    end

    ok_or_error
  end

  # Create unverified smart contract changeset
  defp unverified_smart_contract(address_hash, params, error, error_message, verification_with_files? \\ false) do
    compiler_version = extract_compiler_version_from_params(params)

    attrs =
      address_hash
      |> attributes(params |> Map.put("compiler_version", compiler_version))
      |> Helper.add_contract_code_md5()

    changeset =
      SmartContract.invalid_contract_changeset(
        %SmartContract{address_hash: address_hash},
        attrs,
        error,
        error_message,
        verification_with_files?
      )

    Logger.error("Fluent smart-contract verification #{address_hash} failed because of the error #{inspect(error)}")

    %{changeset | action: :insert}
  end

  # Extract compiler version from params
  defp extract_compiler_version_from_params(params) do
    get_in(params, ["compile_settings", "rustc_version"]) ||
    get_in(params, ["compile_settings", "rustcVersion"]) ||
    ""
  end

  # Build attributes for smart contract
  defp attributes(address_hash, params, abi \\ %{}) do
    %{
      address_hash: address_hash,
      name: params["name"],
      file_path: params["file_path"],
      compiler_version: params["compiler_version"],
      evm_version: nil,
      optimization_runs: nil,
      optimization: false,
      contract_source_code: params["contract_source_code"],
      constructor_arguments: nil,
      external_libraries: [],
      secondary_sources: params["secondary_sources"],
      abi: abi,
      verified_via_sourcify: false,
      verified_via_eth_bytecode_db: false,
      verified_via_verifier_alliance: false,
      partially_verified: false,
      autodetect_constructor_args: false,
      compiler_settings: nil,
      license_type: :none,
      is_blueprint: false,
      language: :solidity, # TODO(d1r1): should we change it to fluent_rust?
      package_name: params["package_name"],
      fluent_metadata: params["fluent_metadata"]
    }
  end
end
