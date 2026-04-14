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
        "compile_settings" => transform_compile_settings(params)
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
  # Supports both new (`commit_ref`) and legacy (`commit_reference`) field names.
  defp transform_git_source(git_source) do
    %{
      "repository_url" => git_source["repository_url"],
      "commit_ref" => git_source["commit_ref"] || git_source["commit_reference"] || git_source["commit"]
    }
  end

  # Transforms user-facing archive source params to the microservice format.
  defp transform_archive_source(archive_source) do
    %{
      "content" => archive_source["content"]
    }
  end

  # Transforms user-facing compile settings to the microservice format.
  # New HTTP schema supports optional `rust_flags`, `rust_toolchain`, `manifest_path`.
  # For backward compatibility, `manifest_path` can still be derived from legacy source fields.
  defp transform_compile_settings(params) do
    settings = params["compile_settings"] || %{}

    %{
      "sdk_version" => settings["sdk_version"],
      "features" => normalize_list(settings["features"]),
      "no_default_features" => settings["no_default_features"] || false,
      "rust_flags" => normalize_list(settings["rust_flags"])
    }
    |> put_if_present("rust_toolchain", settings["rust_toolchain"])
    |> put_if_present("manifest_path", settings["manifest_path"] || legacy_manifest_path(params))
  end

  defp legacy_manifest_path(params) do
    git_source = params["git_source"] || %{}
    archive_source = params["archive_source"] || %{}

    git_source["path_to_cargo_toml_in_repository"] ||
      archive_source["path_to_cargo_toml_in_archive"] ||
      root_to_manifest_path(git_source["root"]) ||
      root_to_manifest_path(archive_source["root"])
  end

  defp root_to_manifest_path(nil), do: nil
  defp root_to_manifest_path(""), do: nil

  defp root_to_manifest_path(root) when is_binary(root) do
    Path.join(root, "Cargo.toml")
  end

  defp root_to_manifest_path(_), do: nil

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp get_chain_id do
    Application.get_env(:block_scout_web, :chain_id) ||
      Application.get_env(:explorer, :chain_id) ||
      raise "Chain ID is not configured in Blockscout."
  end
end
