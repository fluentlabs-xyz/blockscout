defmodule Explorer.SmartContract.Fluent.Verifier do
  @moduledoc """
  Verifies Fluent smart contracts by preparing data for the verification microservice.

  This module handles the verification of Fluent (WASM) smart contracts.
  It constructs the payload required by the `FluentVerifierInterface` by:
  - Transforming the user-provided parameters to match the microservice's expected format.
  - Fetching chain-specific data like `chain_id` and `rpc_endpoint`.
  - Calling the unified verification function in the interface.
  """
  alias EthereumJSONRPC.Utility.CommonHelper
  alias Explorer.Chain.Hash
  alias Explorer.SmartContract.FluentVerifierInterface

  require Logger

  @doc """
  Evaluates the authenticity of a Fluent smart contract.
  """
  @spec evaluate_authenticity(EthereumJSONRPC.address() | Hash.Address.t(), map()) ::
          {:ok, map()} | {:error, any()}
  def evaluate_authenticity(address_hash, params) do
    if FluentVerifierInterface.enabled?() do
      do_evaluate_authenticity(address_hash, params)
    else
      {:error, %{"message" => "Fluent verification is disabled."}}
    end
  rescue
    exception ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        [
          "Error during Fluent contract verification for address: #{inspect(address_hash)}\n",
          "Params: #{inspect(params, limit: :infinity)}\n",
          "Exception: #{Exception.format(:error, exception, stacktrace)}"
        ]
      end)

      {:error, %{"message" => "Internal error during verification: #{Exception.message(exception)}"}}
  end

  defp do_evaluate_authenticity(address_hash, params) do
    # Prepare the payload for the verification service.
    # The user-facing API may have different field names than the microservice.
    # This module is responsible for the translation.
    verification_params =
      %{
        "contract_address" => to_string(address_hash),
        "chain_id" => get_chain_id(),
        "rpc_endpoint" => CommonHelper.get_available_url(),
        "compile_settings" => transform_compile_settings(params["compile_settings"])
      }
      |> Map.merge(prepare_source_payload(params))

    FluentVerifierInterface.verify_wasm(verification_params)
  end

  # Selects the correct source type and transforms its keys to match the proto.
  defp prepare_source_payload(params) do
    cond do
      git_source = params["git_source"] ->
        %{"git_source" => transform_git_source(git_source)}

      archive_source = params["archive_source"] ->
        %{"archive_source" => transform_archive_source(archive_source)}

      true ->
        # This case should be prevented by controller validation.
        raise "Verification request must contain 'git_source' or 'archive_source'."
    end
  end

  # Transforms user-facing git source params to the microservice format.
  defp transform_git_source(git_source) do
    %{
      "repository_url" => git_source["repository_url"],
      # User sends `commit_reference`, microservice expects `commit_ref`.
      "commit_ref" => git_source["commit_reference"],
      # User might send `root` or `path_to_...`, microservice expects `project_path`.
      "project_path" => git_source["root"] || git_source["path_to_cargo_toml_in_repository"] || "."
    }
  end

  # Transforms user-facing archive source params to the microservice format.
  defp transform_archive_source(archive_source) do
    %{
      "content" => archive_source["content"],
      # User might send `root` or `path_to_...`, microservice expects `project_path`.
      "project_path" => archive_source["root"] || archive_source["path_to_cargo_toml_in_archive"] || "."
    }
  end

  # Transforms user-facing compile settings to the microservice format.
  defp transform_compile_settings(settings) do
    %{
      "sdk_version" => settings["sdk_version"],
      "features" => settings["features"] || [],
      "no_default_features" => settings["no_default_features"] || false
    }
  end

  defp get_chain_id do
    Application.get_env(:block_scout_web, :chain_id) ||
      Application.get_env(:explorer, :chain_id) ||
      raise "Chain ID is not configured in Blockscout."
  end
end
