defmodule Explorer.SmartContract.Fluent.Publisher do
  @moduledoc """
  Module responsible for verifying and publishing Fluent smart contracts.

  This module orchestrates the verification process by calling the `Verifier`
  and, upon success, combines the verification metadata with user-provided
  data (like ABI and contract name) to create or update the smart contract
  record in the database.
  """

  require Logger

  alias Explorer.Chain.SmartContract
  alias Explorer.SmartContract.Fluent.Verifier
  alias Explorer.SmartContract.Helper

  @doc """
  Verifies and publishes a Fluent smart contract.

  This is the main entry point for the publishing process. It takes the full
  user-provided payload, initiates verification, and handles the outcome.

  ## Parameters
  - `address_hash`: The contract's address hash.
  - `params`: A map containing the full user request payload, including
    `contract_name`, `abi`, source details, and compile settings.

  ## Returns
  - `{:ok, smart_contract}` if verification and database persistence succeed.
  - `{:error, changeset}` if verification fails or there are validation errors.
  """
  @spec publish(binary() | Explorer.Chain.Hash.t(), %{String.t() => any()}) ::
          {:error, Ecto.Changeset.t()} | {:ok, Explorer.Chain.SmartContract.t()}
  def publish(address_hash, params) do
    Logger.info("Fluent smart contract verification started for address #{inspect(address_hash)}.")

    case Verifier.evaluate_authenticity(address_hash, params) do
      {:ok, verification_result} ->
        process_successful_verification(verification_result, params, address_hash)

      {:error, error} ->
        process_failed_verification(address_hash, params, error)
    end
  end

  #
  # Internal Functions: Success Path
  #

  defp process_successful_verification(verification_result, initial_params, address_hash) do
    # The `verification_result` map corresponds to the `VerificationResult` proto message.
    # The `initial_params` map is the original request from the user.
    prepared_attrs = prepare_attributes(verification_result, initial_params, address_hash)

    abi = initial_params["abi"] || []

    publish_smart_contract(address_hash, prepared_attrs, abi)
  end

  defp prepare_attributes(verification_result, initial_params, address_hash) do
    source_files = verification_result["source_files"] || %{}
    main_file_path = find_main_source_file(source_files)
    main_source_code = Map.get(source_files, main_file_path, "")

    package_name =
      source_files
      |> find_cargo_toml_content()
      |> parse_package_name_from_toml()

    %{
      # User-provided data
      "name" => initial_params["contract_name"],
      "abi" => initial_params["abi"] || [],
      # Data from verifier
      "compiler_version" => verification_result["rustc_version"],
      "contract_source_code" => main_source_code,
      "file_path" => main_file_path,
      "secondary_sources" => prepare_secondary_sources(source_files, main_file_path, address_hash),
      "package_name" => package_name,
      "fluent_metadata" => build_fluent_metadata(verification_result)
    }
  end

  defp publish_smart_contract(address_hash, params, abi) do
    attrs = build_final_attributes(address_hash, params, abi)

    case SmartContract.create_or_update_smart_contract(address_hash, attrs, true) do
      {:ok, _} = ok_or_error ->
        Logger.info("Fluent smart-contract #{inspect(address_hash)} successfully published.")
        ok_or_error

      {:error, _} = ok_or_error ->
        Logger.error("Fluent smart-contract #{inspect(address_hash)} failed to publish: #{inspect(ok_or_error)}")
        ok_or_error
    end
  end

  #
  # Internal Functions: Failure Path
  #

  defp process_failed_verification(address_hash, params, error) do
    error_message = error["error_message"] || "Verification failed with an unknown error."
    Logger.error("Fluent smart-contract verification for #{inspect(address_hash)} failed: #{error_message}")
    {:error, unverified_smart_contract_changeset(address_hash, params, error, error_message)}
  end

  defp unverified_smart_contract_changeset(address_hash, params, error, error_message) do
    attrs =
      address_hash
      |> build_final_attributes(params, params["abi"] || [])
      |> Helper.add_contract_code_md5()

    changeset =
      SmartContract.invalid_contract_changeset(
        %SmartContract{address_hash: address_hash},
        attrs,
        # The `error` itself might be a map, which is fine for the changeset.
        error,
        error_message,
        true
      )

    # The action must be :insert for new unverified attempts
    %{changeset | action: :insert}
  end

  #
  # Attribute Builders and Helpers
  #

  defp build_final_attributes(address_hash, params, abi \\ []) do
    %{
      address_hash: address_hash,
      name: params["name"],
      file_path: params["file_path"],
      compiler_version: params["compiler_version"],
      # Not applicable for WASM contracts
      evm_version: nil,
      # Not applicable
      optimization: false,
      # Not applicable
      optimization_runs: nil,
      contract_source_code: params["contract_source_code"],
      # Not applicable
      constructor_arguments: nil,
      external_libraries: [],
      secondary_sources: params["secondary_sources"],
      abi: abi,
      verified_via_sourcify: false,
      verified_via_eth_bytecode_db: false,
      verified_via_verifier_alliance: false,
      partially_verified: false,
      autodetect_constructor_args: false,
      # Richer data is in fluent_metadata
      compiler_settings: nil,
      license_type: :none,
      is_blueprint: false,
      language: :fluent_rust,
      package_name: params["package_name"],
      fluent_metadata: params["fluent_metadata"]
    }
  end

  # Extracts rich metadata from the verification result for storage.
  defp build_fluent_metadata(verification_result) do
    Map.take(verification_result, [
      "compile_settings",
      "rustc_version",
      "sdk_version",
      "build_platform"
    ])
  end

  # Finds the main source file (lib.rs or main.rs) from the list of source files.
  defp find_main_source_file(source_files) when is_map(source_files) do
    # Priority order for the main file
    candidate_paths = ["src/lib.rs", "lib.rs", "src/main.rs", "main.rs"]

    Enum.find(candidate_paths, &Map.has_key?(source_files, &1)) ||
      source_files |> Map.keys() |> List.first()
  end

  defp find_main_source_file(_), do: nil

  # Prepares secondary source files (all files except the main one).
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

  # Finds and returns the content of Cargo.toml.
  defp find_cargo_toml_content(source_files) when is_map(source_files) do
    Map.get(source_files, "Cargo.toml")
  end

  defp find_cargo_toml_content(_), do: nil

  # Parses the package name from the TOML content. A simple regex is sufficient.
  defp parse_package_name_from_toml(toml_content) when is_binary(toml_content) do
    case Regex.run(~r/^name\s*=\s*"([^"]+)"/m, toml_content) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp parse_package_name_from_toml(_), do: nil
end
