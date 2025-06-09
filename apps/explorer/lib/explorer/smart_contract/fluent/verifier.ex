defmodule Explorer.SmartContract.Fluent.Verifier do
  @moduledoc """
    Verifies Fluent smart contracts by comparing their source code against deployed bytecode.

    This module handles verification of Fluent WASM smart contracts through their Git repository
    or archive source code. It interfaces with a verification microservice that:
    - Fetches source code from the specified Git repository or extracts from archive
    - Compiles the code using the specified rustc and fluentbase-sdk versions
    - Converts WASM to rWASM format
    - Compares the resulting rWASM bytecode hash against the deployed contract bytecode hash
    - Returns verification details including ABI and build metadata
  """
  alias Explorer.Chain.{Hash, SmartContract}
  alias Explorer.SmartContract.FluentVerifierInterface

  require Logger

  @doc """
    Verifies a Fluent smart contract using Git repository source code by comparing against the deployed bytecode using a verification microservice.

    ## Parameters
    - `address_hash`: Contract address
    - `params`: Map containing verification parameters:
      - `git_source`: Git source details
        - `repository_url`: Git repository URL containing contract code
        - `commit_reference`: Git commit hash, tag, or branch used for deployment
        - `path_to_cargo_toml_in_repository`: Optional path to Cargo.toml in repository
      - `compile_settings`: Compilation settings used for the original build
        - `rustc_version`: Rust compiler version
        - `fluentbase_sdk_version`: Fluentbase SDK version
        - `target_triple`: Target triple for WASM compilation
        - `profile`: Build profile (e.g., "release")
        - `features`: List of enabled features
        - `no_default_features`: Whether default features were disabled
        - `cargo_flags`: Additional cargo build flags

    ## Returns
    - `{:ok, map}` with verification details:
      - `contract_name`: Name of the verified contract
      - `abi_json_string`: Contract ABI as JSON string (optional)
      - `wasm_bytecode`: Compiled WASM bytecode (optional)
      - `rwasm_bytecode`: Generated rWASM bytecode (optional)
      - `method_identifiers`: Map of method signatures to selectors
      - `build_metadata`: Detailed build metadata (optional)
    - `{:error, any}` if verification fails or is disabled
  """
  @spec evaluate_authenticity_git(EthereumJSONRPC.address() | Hash.Address.t(), map()) ::
          {:ok, map()} | {:error, any()}
  def evaluate_authenticity_git(address_hash, params) do
    evaluate_authenticity_inner(:git, FluentVerifierInterface.enabled?(), address_hash, params)
  rescue
    exception ->
      Logger.error(fn ->
        [
          "Error while verifying smart-contract address: #{address_hash}, params: #{inspect(params, limit: :infinity, printable_limit: :infinity)}: ",
          Exception.format(:error, exception, __STACKTRACE__)
        ]
      end)
  end

  @doc """
    Verifies a Fluent smart contract using source code archive by comparing against the deployed bytecode using a verification microservice.

    ## Parameters
    - `address_hash`: Contract address
    - `params`: Map containing verification parameters:
      - `archive_source`: Archive source details
        - `source_code_archive`: Base64 encoded archive content
        - `path_to_cargo_toml_in_archive`: Path to Cargo.toml within archive
      - `compile_settings`: Compilation settings used for the original build

    ## Returns
    - `{:ok, map}` with verification details
    - `{:error, any}` if verification fails or is disabled
  """
  @spec evaluate_authenticity_archive(EthereumJSONRPC.address() | Hash.Address.t(), map()) ::
          {:ok, map()} | {:error, any()}
  def evaluate_authenticity_archive(address_hash, params) do
    evaluate_authenticity_inner(:archive, FluentVerifierInterface.enabled?(), address_hash, params)
  rescue
    exception ->
      Logger.error(fn ->
        [
          "Error while verifying smart-contract address: #{address_hash}, params: #{inspect(params, limit: :infinity, printable_limit: :infinity)}: ",
          Exception.format(:error, exception, __STACKTRACE__)
        ]
      end)
  end

  # Verifies the authenticity of a Fluent smart contract using Git repository or archive source code.
  #
  # This function retrieves the deployed rWASM bytecode hash and chain information,
  # which together with passed parameters are required by the verification microservice to
  # validate the contract deployment and verify the source code against the deployed
  # bytecode.
  #
  # ## Parameters
  # - `source_type`: Either `:git` or `:archive` to indicate source type
  # - `true`: Required boolean flag to proceed with verification
  # - `address_hash`: Contract address
  # - `params`: Map containing verification parameters
  #
  # ## Returns
  # - `{:ok, map}` with verification details including ABI, contract name, and build metadata
  # - `{:error, any}` if verification fails
  @spec evaluate_authenticity_inner(:git | :archive, boolean(), EthereumJSONRPC.address() | Hash.Address.t(), map()) ::
          {:ok, map()} | {:error, any()}
  defp evaluate_authenticity_inner(:git, true, address_hash, params) do
    deployed_bytecode_hash = fetch_deployed_bytecode_hash(address_hash)
    chain_id = Application.get_env(:block_scout_web, :chain_id)

    verification_params =
      %{
        "git_source" => Map.get(params, "git_source"),
        "deployed_rwasm_bytecode_hash" => deployed_bytecode_hash,
        "chain_id" => to_string(chain_id),
        "contract_address" => to_string(address_hash),
        "compile_settings" => Map.get(params, "compile_settings")
      }

    FluentVerifierInterface.verify_git_source(verification_params)
  end

  defp evaluate_authenticity_inner(:archive, true, address_hash, params) do
    deployed_bytecode_hash = fetch_deployed_bytecode_hash(address_hash)
    chain_id = Application.get_env(:block_scout_web, :chain_id)

    verification_params =
      %{
        "archive_source" => Map.get(params, "archive_source"),
        "deployed_rwasm_bytecode_hash" => deployed_bytecode_hash,
        "chain_id" => to_string(chain_id),
        "contract_address" => to_string(address_hash),
        "compile_settings" => Map.get(params, "compile_settings")
      }

    FluentVerifierInterface.verify_archive_source(verification_params)
  end

  defp evaluate_authenticity_inner(_source_type, false, _address_hash, _params) do
    {:error, "Fluent verification is disabled"}
  end

  # Retrieves the deployed bytecode hash for a Fluent smart contract.

  # Looks up the contract's bytecode and calculates its hash. This hash is used
  # by the verification service to compare against the compiled source code.

  # ## Parameters
  # - `address_hash`: The address hash of the smart contract as a binary or `t:Hash.Address.t/0`

  # ## Returns
  # - `String.t()` - The hex-encoded hash of the deployed bytecode
  # - `nil` - If no bytecode exists
  @spec fetch_deployed_bytecode_hash(binary() | Hash.Address.t()) :: String.t() | nil
  defp fetch_deployed_bytecode_hash(address_hash) do
    case SmartContract.address_hash_to_smart_contract_with_bytecode(address_hash) do
      %{contract_code: %{bytecode: bytecode}} when not is_nil(bytecode) ->
        # Calculate hash of the bytecode (assuming SHA256 or similar)
        # This might need adjustment based on what hash algorithm the verifier expects
        :crypto.hash(:sha256, bytecode)
        |> Base.encode16(case: :lower)
        |> then(&("0x" <> &1))

      _ ->
        nil
    end
  end
end
