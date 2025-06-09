defmodule Explorer.SmartContract.FluentVerifierInterface do
  @moduledoc """
    Provides an interface for verifying Fluent smart contracts by interacting with a verification
    microservice.

    Handles verification requests for Fluent WASM contracts deployed from source archives or
    Git repositories by communicating with an external verification service.
  """
  alias HTTPoison.Response
  require Logger

  @post_timeout :timer.minutes(5)
  @request_error_msg "Error while sending request to fluent verification microservice"

  @doc """
    Verifies a Fluent WASM smart contract using source code from a Git repository.

    Sends verification request to the verification microservice with repository details
    and deployment information.

    ## Parameters
    - `body`: A map containing:
      - `git_source`: Git source details
        - `repository_url`: Git repository URL containing contract code
        - `commit_reference`: Git commit hash, tag, or branch used for deployment
        - `path_to_cargo_toml_in_repository`: Optional path to Cargo.toml in repository
      - `deployed_rwasm_bytecode_hash`: Hash of deployed rWASM bytecode
      - `chain_id`: Chain identifier where contract is deployed
      - `contract_address`: Address of the deployed contract
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
    - `{:error, any}` if verification fails
  """
  @spec verify_git_source(map()) :: {:ok, map()} | {:error, any()}
  def verify_git_source(
        %{
          "git_source" => _,
          "deployed_rwasm_bytecode_hash" => _,
          "chain_id" => _,
          "contract_address" => _,
          "compile_settings" => _
        } = body
      ) do
    http_post_request(verify_wasm_url(), body)
  end

  @doc """
    Verifies a Fluent WASM smart contract using a source code archive.

    Sends verification request to the verification microservice with archive content
    and deployment information.

    ## Parameters
    - `body`: A map containing:
      - `archive_source`: Archive source details
        - `source_code_archive`: Base64 encoded archive content
        - `path_to_cargo_toml_in_archive`: Path to Cargo.toml within archive
      - `deployed_rwasm_bytecode_hash`: Hash of deployed rWASM bytecode
      - `chain_id`: Chain identifier where contract is deployed
      - `contract_address`: Address of the deployed contract
      - `compile_settings`: Compilation settings used for the original build

    ## Returns
    - `{:ok, map}` with verification details
    - `{:error, any}` if verification fails
  """
  @spec verify_archive_source(map()) :: {:ok, map()} | {:error, any()}
  def verify_archive_source(
        %{
          "archive_source" => _,
          "deployed_rwasm_bytecode_hash" => _,
          "chain_id" => _,
          "contract_address" => _,
          "compile_settings" => _
        } = body
      ) do
    http_post_request(verify_wasm_url(), body)
  end

  @spec http_post_request(String.t(), map()) :: {:ok, map()} | {:error, any()}
  defp http_post_request(url, body) do
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, Jason.encode!(body), headers, recv_timeout: @post_timeout) do
      {:ok, %Response{body: body, status_code: _}} ->
        process_verifier_response(body)

      {:error, error} ->
        Logger.error(fn ->
          [
            "Error while sending request to verification microservice url: #{url}, body: #{inspect(body, limit: :infinity, printable_limit: :infinity)}: ",
            inspect(error, limit: :infinity, printable_limit: :infinity)
          ]
        end)

        {:error, @request_error_msg}
    end
  end

  @spec http_get_request(String.t()) :: {:ok, map()} | {:error, any()}
  defp http_get_request(url) do
    case HTTPoison.get(url) do
      {:ok, %Response{body: body, status_code: 200}} ->
        process_verifier_response(body)

      {:ok, %Response{body: body, status_code: _}} ->
        {:error, body}

      {:error, error} ->
        Logger.error(fn ->
          [
            "Error while sending request to verification microservice url: #{url}: ",
            inspect(error, limit: :infinity, printable_limit: :infinity)
          ]
        end)

        {:error, @request_error_msg}
    end
  end

  @doc """
    Retrieves a list of supported versions from the verification microservice.

    ## Returns
    - `{:ok, map}` - Map containing `rustc_versions` and `fluentbase_sdk_versions` lists
    - `{:error, any()}` - Error message if the request fails
  """
  @spec get_versions_list() :: {:ok, map()} | {:error, any()}
  def get_versions_list do
    http_get_request(supported_versions_url())
  end

  @spec process_verifier_response(binary()) :: {:ok, map()} | {:error, any()}
  defp process_verifier_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        process_verifier_response(decoded)

      _ ->
        {:error, body}
    end
  end

  # Handles successful response from `verify-wasm` endpoint (snake_case)
  @spec process_verifier_response(map()) :: {:ok, map()}
  defp process_verifier_response(%{"status" => "STATUS_SUCCESS", "success_details" => success_details}) do
    {:ok, success_details}
  end

  # Handles successful response from `verify-wasm` endpoint (camelCase)
  @spec process_verifier_response(map()) :: {:ok, map()}
  defp process_verifier_response(%{"status" => "STATUS_SUCCESS", "successDetails" => success_details}) do
    {:ok, success_details}
  end

  # Handles failed response from `verify-wasm` endpoint (snake_case)
  @spec process_verifier_response(map()) :: {:error, map()}
  defp process_verifier_response(%{"status" => "STATUS_FAILURE", "failure_details" => failure_details}) do
    {:error, failure_details}
  end

  # Handles failed response from `verify-wasm` endpoint (camelCase)
  @spec process_verifier_response(map()) :: {:error, map()}
  defp process_verifier_response(%{"status" => "STATUS_FAILURE", "failureDetails" => failure_details}) do
    {:error, failure_details}
  end

  # Handles response from `supported-versions` endpoint (snake_case)
  @spec process_verifier_response(map()) :: {:ok, map()}
  defp process_verifier_response(%{"rustc_versions" => rustc_versions, "fluentbase_sdk_versions" => sdk_versions}) do
    {:ok, %{rustc_versions: rustc_versions, fluentbase_sdk_versions: sdk_versions}}
  end

  # Handles response from `supported-versions` endpoint (camelCase)
  @spec process_verifier_response(map()) :: {:ok, map()}
  defp process_verifier_response(%{"rustcVersions" => rustc_versions, "fluentbaseSdkVersions" => sdk_versions}) do
    {:ok, %{rustc_versions: rustc_versions, fluentbase_sdk_versions: sdk_versions}}
  end

  @spec process_verifier_response(any()) :: {:error, any()}
  defp process_verifier_response(other) do
    {:error, other}
  end

  defp verify_wasm_url, do: base_url() <> "/api/v1/fluent/verify-wasm"

  defp supported_versions_url, do: base_url() <> "/api/v1/fluent/supported-versions"

  defp base_url, do: Application.get_env(:explorer, __MODULE__)[:service_url]

  def enabled?,
    do: !is_nil(base_url()) && Application.get_env(:explorer, :chain_type) == :fluent
end
