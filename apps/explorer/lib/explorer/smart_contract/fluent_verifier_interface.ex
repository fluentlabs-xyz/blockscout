defmodule Explorer.SmartContract.FluentVerifierInterface do
  @moduledoc """
  Adapter for the fluent-verifier microservice.

  This module provides a client interface for verifying Fluent (WASM) smart
  contracts by communicating with an external verification service. It handles
  the construction, sending, and processing of verification requests.
  """
  alias HTTPoison.Response
  require Logger

  @post_timeout :timer.minutes(5)
  @request_error_msg "Error while sending request to fluent verification microservice"
  @doc """
  Verifies a Fluent WASM smart contract by calling the verifier microservice.

  This function sends a single, unified verification request. The `params` map
  is expected to be a complete payload that matches the `VerifyWasmRequest`
  proto definition, containing source code (either from Git or an archive),
  compile settings, and chain-related information.

  ## Parameters
    - `params`: A map containing the full verification request payload.

  ## Returns
    - `{:ok, result_map}` on successful verification, where `result_map` corresponds
      to the `VerificationResult` proto message.
    - `{:error, error_map}` if verification fails at any stage.
  """
  @spec verify_wasm(map()) :: {:ok, map()} | {:error, map()}
  def verify_wasm(params) do
    http_post_request(verify_wasm_url(), params)
  end

  @doc """
  Retrieves a list of available SDK versions from the verification microservice.

  ## Parameters
    - `include_prerelease`: (Optional) A boolean to indicate whether to include
      pre-release versions in the response. Defaults to `false`.

  ## Returns
    - `{:ok, versions_map}` - A map containing `sdk_versions` and `latest_stable`.
    - `{:error, any()}` - An error tuple if the request fails.
  """
  @spec list_available_versions(boolean()) :: {:ok, map()} | {:error, any()}
  def list_available_versions(include_prerelease \\ false) do
    body = %{include_prerelease: include_prerelease}
    http_post_request(list_versions_url(), body)
  end

  @doc """
  Provides a backward-compatible wrapper for the old `get_versions_list/0` function.

  This function delegates the call to the new `list_available_versions/1` function
  with default parameters, ensuring that older parts of the application that
  still rely on the old interface continue to work without modification.
  """
  @spec get_versions_list() :: {:ok, map()} | {:error, any()}
  def get_versions_list() do
    list_available_versions(true)
  end

  @doc """
  Checks if the Fluent verifier microservice is enabled in the configuration.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    !is_nil(base_url())
  end

  #
  # Internal Functions
  #

  defp http_post_request(url, body) do
    headers = [{"Content-Type", "application/json"}]

    Logger.info(fn ->
      [
        "Attempting to send request to Fluent Verifier.",
        "\n  URL: #{url}",
        "\n  Request Body (Elixir map): #{inspect(body, pretty: true, limit: :infinity)}"
      ]
    end)

    encoded_body = Jason.encode!(body)

    case HTTPoison.post(url, encoded_body, headers, recv_timeout: @post_timeout) do
      {:ok, %Response{body: response_body, status_code: status}} when status in 200..299 ->
        process_response(response_body)

      {:ok, %Response{body: response_body, status_code: status}} ->
        Logger.error("Fluent verifier returned non-2xx status #{status}: #{response_body}")
        {:error, %{"message" => "Verification service returned status #{status}"}}

      {:error, %HTTPoison.Error{reason: reason} = error} ->
        Logger.error(fn ->
          [
            "Error sending request to fluent verifier at #{url}: #{inspect(reason)}",
            ", body: #{inspect(body, limit: :infinity, printable_limit: :infinity)}"
          ]
        end)

        {:error, %{"message" => @request_error_msg, "details" => inspect(error)}}
    end
  end

  defp process_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded_response} ->
        process_decoded_response(decoded_response)

      {:error, _} ->
        {:error, %{"message" => "Failed to decode JSON response from verifier", "details" => body}}
    end
  end

  # Route the decoded response based on its structure
  defp process_decoded_response(%{"status" => status} = response),
    do: process_verification_response(status, response)

  defp process_decoded_response(%{"sdk_versions" => _} = response),
    do: {:ok, response}

  defp process_decoded_response(other),
    do: {:error, %{"message" => "Invalid response format from verifier", "details" => other}}

  # Handle the verification response specifically
  defp process_verification_response("STATUS_SUCCESS", response) do
    case Map.get(response, "result") do
      nil -> {:error, %{"message" => "Successful verification response missing 'result' field."}}
      result -> {:ok, result}
    end
  end

  defp process_verification_response(status, response) do
    error_message = response["error_message"] || "An unknown error occurred during verification."
    {:error, %{"status" => status, "error_message" => error_message}}
  end

  #
  # URL Helpers
  #

  defp base_url, do: Application.get_env(:explorer, __MODULE__)[:service_url]
  defp verify_wasm_url, do: base_url() <> "/api/v1/fluent/verify-wasm"
  defp list_versions_url, do: base_url() <> "/api/v1/fluent/available-versions"
end
