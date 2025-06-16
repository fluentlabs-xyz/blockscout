defmodule Explorer.SmartContract.Fluent.Verifier do
  @moduledoc """
  Verifies Fluent smart contracts by comparing their source code against deployed bytecode.

  This module handles verification of Fluent WASM smart contracts through their Git repository
  or archive source code. It interfaces with a verification microservice that:
  - Fetches source code from the specified Git repository or extracts from archive
  - Compiles the code using the specified rustc and fluentbase-sdk versions
  - Compares the resulting bytecode against the deployed contract bytecode
  - Returns verification details including ABI and build metadata
  """
  alias EthereumJSONRPC.Utility.CommonHelper
  alias Explorer.Chain.{Hash, SmartContract}
  alias Explorer.SmartContract.FluentVerifierInterface

  require Logger

  @doc """
  Verifies a Fluent smart contract using Git repository source code.

  ## Parameters
  - `address_hash`: Contract address
  - `params`: Map containing verification parameters

  ## Returns
  - `{:ok, map}` with verification details
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

      {:error, "Verification failed: #{Exception.message(exception)}"}
  end

  @doc """
  Verifies a Fluent smart contract using source code archive.

  ## Parameters
  - `address_hash`: Contract address
  - `params`: Map containing verification parameters

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

      {:error, "Verification failed: #{Exception.message(exception)}"}
  end

  # Internal verification logic
  @spec evaluate_authenticity_inner(:git | :archive, boolean(), EthereumJSONRPC.address() | Hash.Address.t(), map()) ::
          {:ok, map()} | {:error, any()}
  defp evaluate_authenticity_inner(:git, true, address_hash, params) do
    chain_id = get_chain_id()
    rpc_endpoint = CommonHelper.get_available_url()

    verification_params =
      params
      |> prepare_git_params()
      |> Map.put("contract_address", to_string(address_hash))
      |> Map.put("chain_id", to_string(chain_id))
      |> Map.put("rpc_endpoint", rpc_endpoint)

    FluentVerifierInterface.verify_git_source(verification_params)
  end

  defp evaluate_authenticity_inner(:archive, true, address_hash, params) do
    chain_id = get_chain_id()
    rpc_endpoint = CommonHelper.get_available_url()

    verification_params =
      params
      |> prepare_archive_params()
      |> Map.put("contract_address", to_string(address_hash))
      |> Map.put("chain_id", to_string(chain_id))
      |> Map.put("rpc_endpoint", rpc_endpoint)

    FluentVerifierInterface.verify_archive_source(verification_params)
  end

  defp evaluate_authenticity_inner(_source_type, false, _address_hash, _params) do
    {:error, "Fluent verification is disabled"}
  end

  # Prepare Git parameters for verification
  defp prepare_git_params(params) do
    %{
      "git_source" => params["git_source"],
      "compile_settings" => params["compile_settings"]
    }
  end

  # Prepare archive parameters for verification
  defp prepare_archive_params(params) do
    %{
      "archive_source" => params["archive_source"],
      "compile_settings" => params["compile_settings"]
    }
  end

  # Get chain ID from configuration
  defp get_chain_id do
    Application.get_env(:block_scout_web, :chain_id) ||
    Application.get_env(:explorer, :chain_id) ||
    raise "Chain ID not configured"
  end
end
