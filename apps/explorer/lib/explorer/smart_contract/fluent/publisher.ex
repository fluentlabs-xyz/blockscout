defmodule Explorer.SmartContract.Fluent.Publisher do
  @moduledoc """
    Module responsible for verifying and publishing Fluent smart contracts.

    The verification process includes:
    1. Initiating verification through a microservice that compares Git repository
       or archive source code against deployed rWASM bytecode
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

    Initiates verification of a contract through the verification microservice. On
    successful verification, processes and stores the contract details in the
    database. On failure, creates an invalid changeset with appropriate error
    messages.

    ## Parameters
    - `address_hash`: The contract's address hash as binary or `t:Explorer.Chain.Hash.t/0`
    - `params`: Map containing verification parameters:
      - `"git_source"`: Git source details
        - `"repository_url"`: Git repository URL containing contract code
        - `"commit_reference"`: Git commit hash, tag, or branch used for deployment
        - `"path_to_cargo_toml_in_repository"`: Optional path to Cargo.toml in repository
      - `"compile_settings"`: Compilation settings used for the original build
        - `"rustc_version"`: Rust compiler version
        - `"fluentbase_sdk_version"`: Fluentbase SDK version
        - `"target_triple"`: Target triple for WASM compilation
        - `"profile"`: Build profile (e.g., "release")
        - `"features"`: List of enabled features
        - `"no_default_features"`: Whether default features were disabled
        - `"cargo_flags"`: Additional cargo build flags
      - `"source_files"`: Optional - pre-fetched source files from the repository

    ## Returns
    - `{:ok, smart_contract}` if verification and database storage succeed
    - `{:error, changeset}` if verification fails or there are validation errors
  """
  @spec publish_git(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}) ::
          {:error, Ecto.Changeset.t()} | {:ok, Explorer.Chain.SmartContract.t()}
  def publish_git(address_hash, params) do
    Logger.info(@sc_verification_via_git_repository_started)

    case Verifier.evaluate_authenticity_git(address_hash, params) do
      {:ok, %{"contract_name" => _, "build_metadata" => _} = result_params} ->
        # Include source files from params if available
        result_with_sources =
          if Map.has_key?(params, "source_files") do
            Map.put(result_params, "source_files", params["source_files"])
          else
            result_params
          end

        process_verifier_response(result_with_sources, address_hash)

      {:error, %{"error_message" => error_message} = error_details} ->
        {:error, unverified_smart_contract(address_hash, params, error_details, error_message)}

      {:error, %{"errorMessage" => error_message} = error_details} ->
        {:error, unverified_smart_contract(address_hash, params, error_details, error_message)}

      {:error, error} ->
        {:error, unverified_smart_contract(address_hash, params, error, nil)}

      _ ->
        {:error, unverified_smart_contract(address_hash, params, "Unexpected error", nil)}
    end
  end

  @doc """
    Verifies and publishes a Fluent smart contract using source code archive.

    Initiates verification of a contract through the verification microservice. On
    successful verification, processes and stores the contract details in the
    database. On failure, creates an invalid changeset with appropriate error
    messages.

    ## Parameters
    - `address_hash`: The contract's address hash as binary or `t:Explorer.Chain.Hash.t/0`
    - `params`: Map containing verification parameters:
      - `"archive_source"`: Archive source details
        - `"source_code_archive"`: Base64 encoded archive content
        - `"path_to_cargo_toml_in_archive"`: Path to Cargo.toml within archive
      - `"compile_settings"`: Compilation settings used for the original build
      - `"source_files"`: Map of file paths to file contents extracted from the archive

    ## Returns
    - `{:ok, smart_contract}` if verification and database storage succeed
    - `{:error, changeset}` if verification fails or there are validation errors
  """
  @spec publish_archive(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}) ::
          {:error, Ecto.Changeset.t()} | {:ok, Explorer.Chain.SmartContract.t()}
  def publish_archive(address_hash, params) do
    Logger.info(@sc_verification_via_archive_started)

    case Verifier.evaluate_authenticity_archive(address_hash, params) do
      {:ok, %{"contract_name" => _, "build_metadata" => _} = result_params} ->
        # Archive verification should have source files in params
        result_with_sources = Map.put(result_params, "source_files", params["source_files"])
        process_verifier_response(result_with_sources, address_hash)

      {:error, %{"error_message" => error_message} = error_details} ->
        {:error, unverified_smart_contract(address_hash, params, error_details, error_message, true)}

      {:error, %{"errorMessage" => error_message} = error_details} ->
        {:error, unverified_smart_contract(address_hash, params, error_details, error_message, true)}

      {:error, error} ->
        {:error, unverified_smart_contract(address_hash, params, error, nil, true)}

      _ ->
        {:error, unverified_smart_contract(address_hash, params, "Unexpected error", nil, true)}
    end
  end

  # Processes successful Fluent contract verification response and stores contract data.
  #
  # Takes the verification response from `evaluate_authenticity_git/2` or `evaluate_authenticity_archive/2`
  # containing verified contract details and prepares them for storage in the database.
  # The source files are extracted from params or response.
  #
  # ## Parameters
  # - `response`: Verification response map containing:
  #   - `contract_name`: Name of the verified contract
  #   - `abi_json_string`: Contract ABI as JSON string (optional)
  #   - `method_identifiers`: Map of method signatures to selectors
  #   - `build_metadata`: Detailed build metadata containing sources and settings
  #   - `source_files`: Map of file paths to file contents (optional)
  # - `address_hash`: The contract's address hash as binary or `t:Explorer.Chain.Hash.t/0`
  #
  # ## Returns
  # - `{:ok, smart_contract}` if database storage succeeds
  # - `{:error, changeset}` if there are validation errors
  # - `{:error, message}` if the database operation fails
  @spec process_verifier_response(%{String.t() => any()}, binary() | Explorer.Chain.Hash.t()) ::
          {:ok, Explorer.Chain.SmartContract.t()} | {:error, Ecto.Changeset.t() | String.t()}
  defp process_verifier_response(
         %{
           "contract_name" => contract_name,
           "build_metadata" => build_metadata
         } = response,
         address_hash
       ) do
    abi_string = Map.get(response, "abi_json_string") || Map.get(response, "abiJsonString")

    # Extract metadata
    sources_metadata = get_in(build_metadata, ["sources"]) || %{}
    settings = get_in(build_metadata, ["settings"]) || %{}
    compiler_info = get_in(build_metadata, ["compiler"]) || %{}
    contract_info = get_in(settings, ["contract_info"]) || get_in(settings, ["contractInfo"]) || %{}

    # Get source files from response (passed from publish_git/publish_archive)
    source_files = Map.get(response, "source_files", %{})

    # Determine the main source file path
    main_file_path = find_main_source_file_path(sources_metadata, source_files, @default_file_name)

    # Get the main source code
    main_source_code = Map.get(source_files, main_file_path, "")

    # Process secondary sources
    secondary_sources =
      source_files
      |> Enum.reject(fn {path, _content} -> path == main_file_path end)
      |> Enum.map(fn {path, content} ->
        %{
          "file_name" => path,
          "contract_source_code" => content,
          "address_hash" => address_hash
        }
      end)

    # Extract compiler version
    compiler_version = Map.get(compiler_info, "version", "")

    # Extract package name
    package_name = Map.get(contract_info, "name", "")

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

  # Finds the main source file path, preferring paths that exist in source_files
  @spec find_main_source_file_path(map(), map(), String.t()) :: String.t()
  defp find_main_source_file_path(sources_metadata, source_files, default) do
    metadata_paths = Map.keys(sources_metadata)
    available_paths = Map.keys(source_files)

    # Prefer paths that exist in both metadata and actual source files
    candidate_paths = [default, "lib.rs", "src/lib.rs"]

    # Find the first candidate that exists in available source files
    found_path = Enum.find(candidate_paths, fn path ->
      path in available_paths
    end)

    # If not found, try metadata paths
    found_path || Enum.find(metadata_paths, fn path ->
      path in available_paths
    end) || List.first(available_paths) || default
  end

  # Stores information about a verified Fluent smart contract in the database.
  #
  # ## Parameters
  # - `address_hash`: The contract's address hash as binary or `t:Explorer.Chain.Hash.t/0`
  # - `params`: Map containing contract details:
  #   - `name`: Contract name
  #   - `file_path`: Path to the contract source file
  #   - `compiler_version`: Version of the Rust compiler
  #   - `contract_source_code`: Source code of the contract
  #   - `secondary_sources`: Additional source files
  #   - `package_name`: Package name for Fluent contract
  #   - `fluent_metadata`: Build metadata from verification
  # - `abi`: Contract's ABI (Application Binary Interface)
  #
  # ## Returns
  # - `{:ok, smart_contract}` if publishing succeeds
  # - `{:error, changeset}` if there are validation errors
  # - `{:error, message}` if the database operation fails
  @spec publish_smart_contract(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}, map()) ::
          {:error, Ecto.Changeset.t() | String.t()} | {:ok, Explorer.Chain.SmartContract.t()}
  defp publish_smart_contract(address_hash, params, abi) do
    attrs = address_hash |> attributes(params, abi)

    ok_or_error = SmartContract.create_or_update_smart_contract(address_hash, attrs, false)

    case ok_or_error do
      {:ok, _} ->
        Logger.info("Fluent smart-contract #{address_hash} successfully published")

      {:error, error} ->
        Logger.error("Fluent smart-contract #{address_hash} failed to publish: #{inspect(error)}")
    end

    ok_or_error
  end

  # Creates an invalid changeset for a Fluent smart contract that failed verification.
  #
  # Prepares contract attributes with MD5 hash of bytecode and creates an invalid changeset
  # with appropriate error messages. The changeset is marked with `:insert` action to
  # indicate a failed verification attempt.
  #
  # ## Parameters
  # - `address_hash`: The contract's address hash
  # - `params`: Map containing contract details from verification attempt
  # - `error`: The verification error that occurred
  # - `error_message`: Optional custom error message
  # - `verification_with_files?`: Boolean indicating if verification used source files.
  #   Defaults to `false`
  #
  # ## Returns
  # An invalid `t:Ecto.Changeset.t/0` with:
  # - Contract attributes including MD5 hash of bytecode
  # - Error message attached to appropriate field
  # - Action set to `:insert`
  @spec unverified_smart_contract(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}, any(), any(), boolean()) ::
          Ecto.Changeset.t()
  defp unverified_smart_contract(address_hash, params, error, error_message, verification_with_files? \\ false) do
    compiler_version =
      get_in(params, ["compile_settings", "rustc_version"]) ||
      get_in(params, ["compile_settings", "rustcVersion"]) ||
      ""

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
      language: :fluent_rust,
      package_name: params["package_name"],
      fluent_metadata: params["fluent_metadata"]
    }
  end
end
