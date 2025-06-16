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

  # Default RPC endpoints per chain
  @default_rpc_endpoints %{
    "20993" => "https://rpc.dev.gblend.xyz"
  }

  # Verification status constants
  @status_success "STATUS_SUCCESS"
  @status_bytecode_mismatch "STATUS_BYTECODE_MISMATCH"
  @status_compilation_failed "STATUS_COMPILATION_FAILED"
  @status_invalid_source "STATUS_INVALID_SOURCE"
  @status_network_error "STATUS_NETWORK_ERROR"
  @status_unsupported_version "STATUS_UNSUPPORTED_VERSION"
  @status_error "STATUS_ERROR"

  @doc """
  Verifies a Fluent WASM smart contract using source code from a Git repository.

  ## Parameters
  - `body`: A map containing git source details and compilation settings

  ## Returns
  - `{:ok, map}` with verification details
  - `{:error, any}` if verification fails
  """
  @spec verify_git_source(map()) :: {:ok, map()} | {:error, any()}
  def verify_git_source(body) do
    body
    |> build_git_verification_request()
    |> send_verification_request()
  end

  @doc """
  Verifies a Fluent WASM smart contract using a source code archive.

  ## Parameters
  - `body`: A map containing archive source details and compilation settings

  ## Returns
  - `{:ok, map}` with verification details
  - `{:error, any}` if verification fails
  """
  @spec verify_archive_source(map()) :: {:ok, map()} | {:error, any()}
  def verify_archive_source(body) do
    body
    |> build_archive_verification_request()
    |> send_verification_request()
  end

  @doc """
  Retrieves a list of supported versions from the verification microservice.

  ## Returns
  - `{:ok, map}` - Map containing `rustc_versions` and `sdk_versions` lists
  - `{:error, any()}` - Error message if the request fails
  """
  @spec get_versions_list() :: {:ok, map()} | {:error, any()}
  def get_versions_list do
    http_get_request(supported_versions_url())
  end

  @doc """
  Checks if the Fluent verifier is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    !is_nil(base_url()) && Application.get_env(:explorer, :chain_type) == :fluent
  end

  # Request builders

  defp build_git_verification_request(body) do
    %{
      "git_source" => build_git_source(body["git_source"]),
      "contract_address" => body["contract_address"],
      "chain_id" => body["chain_id"],
      "rpc_endpoint" => get_rpc_endpoint(body),
      "compile_settings" => transform_compile_settings(body["compile_settings"])
    }
  end

  defp build_archive_verification_request(body) do
    %{
      "archive_source" => build_archive_source(body["archive_source"]),
      "contract_address" => body["contract_address"],
      "chain_id" => body["chain_id"],
      "rpc_endpoint" => get_rpc_endpoint(body),
      "compile_settings" => transform_compile_settings(body["compile_settings"])
    }
  end

  defp build_git_source(git_source) do
    %{
      "repository_url" => git_source["repository_url"],
      "commit_ref" => get_commit_ref(git_source),
      "project_path" => get_project_path(git_source)
    }
  end

  defp build_archive_source(archive_source) do
    %{
      "content" => decode_archive_content(archive_source["source_code_archive"]),
      "project_path" => get_archive_project_path(archive_source)
    }
  end

  # Helper functions for extracting fields

  defp get_commit_ref(git_source) do
    git_source["commit_reference"] || git_source["commit_ref"]
  end

  defp get_project_path(git_source) do
    git_source["path_to_cargo_toml_in_repository"] ||
    git_source["project_path"] ||
    "."
  end

  defp get_archive_project_path(archive_source) do
    archive_source["path_to_cargo_toml_in_archive"] ||
    archive_source["project_path"] ||
    "."
  end

  defp get_rpc_endpoint(%{"rpc_endpoint" => rpc} = _body) when not is_nil(rpc), do: rpc
  defp get_rpc_endpoint(%{"chain_id" => chain_id}), do: construct_rpc_endpoint(chain_id)

  defp decode_archive_content(content) do
    Base.decode64!(content)
  rescue
    _ -> raise "Invalid base64 encoded archive content"
  end

  # Transform compile settings to match proto structure
  defp transform_compile_settings(settings) when is_map(settings) do
    %{
      "rustc_version" => get_rustc_version(settings),
      "sdk_version" => get_sdk_version(settings),
      "profile" => settings["profile"] || "release",
      "features" => settings["features"] || [],
      "no_default_features" => get_no_default_features(settings)
    }
  end

  defp transform_compile_settings(_), do: %{}

  defp get_rustc_version(settings) do
    settings["rustc_version"] || settings["rustcVersion"]
  end

  defp get_sdk_version(settings) do
    settings["fluentbase_sdk_version"] ||
    settings["sdkVersion"] ||
    settings["sdk_version"]
  end

  defp get_no_default_features(settings) do
    settings["no_default_features"] ||
    settings["noDefaultFeatures"] ||
    false
  end

  # Construct RPC endpoint if not provided
  defp construct_rpc_endpoint(chain_id) do
    @default_rpc_endpoints[chain_id] ||
    Application.get_env(:ethereum_jsonrpc, :rpc_url) ||
    ""
  end

  # HTTP request handling

  defp send_verification_request(request_body) do
    http_post_request(verify_wasm_url(), request_body)
  end

  defp http_post_request(url, body) do
    headers = [{"Content-Type", "application/json"}]
    encoded_body = Jason.encode!(body)

    case HTTPoison.post(url, encoded_body, headers, recv_timeout: @post_timeout) do
      {:ok, %Response{body: response_body, status_code: status}} when status in 200..299 ->
        process_verifier_response(response_body)

      {:ok, %Response{body: response_body, status_code: status}} ->
        handle_http_error(status, response_body)

      {:error, error} ->
        handle_request_error(url, body, error)
    end
  end

  defp http_get_request(url) do
    case HTTPoison.get(url) do
      {:ok, %Response{body: body, status_code: 200}} ->
        process_verifier_response(body)

      {:ok, %Response{body: body, status_code: status}} ->
        handle_http_error(status, body)

      {:error, error} ->
        handle_request_error(url, nil, error)
    end
  end

  defp handle_http_error(status_code, body) do
    Logger.error("Verification service returned status #{status_code}: #{body}")
    {:error, "Service returned status #{status_code}"}
  end

  defp handle_request_error(url, body, error) do
    Logger.error(fn ->
      [
        "Error while sending request to verification microservice url: #{url}",
        if(body, do: ", body: #{inspect(body, limit: :infinity, printable_limit: :infinity)}", else: ""),
        ": ",
        inspect(error, limit: :infinity, printable_limit: :infinity)
      ]
    end)

    {:error, @request_error_msg}
  end

  # Response processing

  defp process_verifier_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        process_decoded_response(decoded)

      {:error, _} ->
        {:error, "Failed to decode response: #{body}"}
    end
  end

  defp process_decoded_response(%{"status" => status} = response) do
    process_verification_status(status, response)
  end

  defp process_decoded_response(%{"rustc_versions" => _, "sdk_versions" => _} = response) do
    process_versions_response(response)
  end

  # Legacy format support
  defp process_decoded_response(%{"rustcVersions" => _, "sdkVersions" => _} = response) do
    process_versions_response(response)
  end

  defp process_decoded_response(other) do
    {:error, %{
      "status" => @status_error,
      "error_message" => "Invalid response format",
      "details" => other
    }}
  end

  # Process verification status
  defp process_verification_status(@status_success, response) do
    process_success_response(response)
  end

  defp process_verification_status(status, response) when status in [
    @status_bytecode_mismatch,
    @status_compilation_failed,
    @status_invalid_source,
    @status_network_error,
    @status_unsupported_version,
    @status_error
  ] do
    {:error, build_error_response(status, response)}
  end

  defp process_verification_status(status, _response) do
    {:error, %{
      "status" => @status_error,
      "error_message" => "Unknown status: #{status}"
    }}
  end

  defp build_error_response(status, response) do
    %{
      "status" => status,
      "error_message" => response["error_message"] || get_default_error_message(status)
    }
  end

  defp get_default_error_message(@status_bytecode_mismatch),
    do: "Bytecode verification failed: compiled bytecode does not match deployed bytecode"
  defp get_default_error_message(@status_compilation_failed),
    do: "Compilation failed"
  defp get_default_error_message(@status_invalid_source),
    do: "Invalid source code or configuration"
  defp get_default_error_message(@status_network_error),
    do: "Network or RPC error"
  defp get_default_error_message(@status_unsupported_version),
    do: "Unsupported compiler or SDK version"
  defp get_default_error_message(_),
    do: "Unknown error occurred"

  # Process successful verification
  defp process_success_response(%{"result" => result, "contract_name" => contract_name}) do
    {:ok, build_success_response(result, contract_name)}
  end

  defp process_success_response(%{"contract_name" => contract_name}) do
    {:ok, %{
      "contract_name" => contract_name,
      "error_message" => "Response missing result field"
    }}
  end

  defp build_success_response(result, contract_name) do
    %{
      "contract_name" => contract_name,
      "abi_json_string" => result["abi_json"],
      "build_metadata" => build_metadata(result, contract_name),
      "source_files" => result["source_files"] || %{}
    }
  end

  defp build_metadata(result, contract_name) do
    compile_settings = result["compile_settings_used"] || %{}
    metadata = result["metadata"] || %{}

    %{
      "sources" => transform_source_files_to_metadata(result["source_files"]),
      "settings" => build_settings(compile_settings, contract_name, result),
      "compiler" => %{
        "version" => metadata["compiler_version_full"]
      }
    }
  end

  defp build_settings(compile_settings, contract_name, result) do
    %{
      "rustc_version" => compile_settings["rustc_version"],
      "fluentbase_sdk_version" => compile_settings["sdk_version"],
      "profile" => compile_settings["profile"],
      "features" => compile_settings["features"],
      "no_default_features" => compile_settings["no_default_features"],
      "contract_info" => %{
        "name" => contract_name,
        "version" => extract_version_from_metadata(result)
      }
    }
  end

  # Process versions response
  defp process_versions_response(response) do
    {:ok, %{
      rustc_versions: response["rustc_versions"] || response["rustcVersions"],
      fluentbase_sdk_versions: response["sdk_versions"] || response["sdkVersions"]
    }}
  end

  # Transform source files to metadata format
  defp transform_source_files_to_metadata(source_files) when is_map(source_files) do
    Map.new(source_files, fn {path, content} ->
      {path, %{"content" => content}}
    end)
  end

  defp transform_source_files_to_metadata(_), do: %{}

  # Extract version from metadata
  defp extract_version_from_metadata(%{"metadata" => metadata}) do
    metadata["package_version"] || metadata["version"] || "0.1.0"
  end

  defp extract_version_from_metadata(_), do: "0.1.0"

  # URL helpers
  defp verify_wasm_url, do: base_url() <> "/api/v1/fluent/verify-wasm"
  defp supported_versions_url, do: base_url() <> "/api/v1/fluent/supported-versions"
  defp base_url, do: Application.get_env(:explorer, __MODULE__)[:service_url]
end
