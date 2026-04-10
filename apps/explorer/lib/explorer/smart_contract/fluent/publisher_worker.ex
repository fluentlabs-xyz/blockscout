defmodule Explorer.SmartContract.Fluent.PublisherWorker do
  @moduledoc """
  Processes Fluent smart contract verification requests asynchronously.

  This worker handles verification of Fluent (WASM) smart contracts by taking a
  unified verification request from the job queue, delegating it to the
  `Explorer.SmartContract.Fluent.Publisher`, and broadcasting the result.
  """

  require Logger

  use Que.Worker, concurrency: 5

  alias Explorer.Chain.Events.Publisher, as: EventsPublisher
  alias Explorer.SmartContract.Fluent.Publisher

  @doc """
  Performs the verification task for a Fluent smart contract.

  This function is the single entry point for the worker. It expects a unified
  `params` map that contains all necessary information for verification,
  including `address_hash`, `contract_name`, `abi`, source details, and
  compile settings.

  ## Parameters
  - `{"fluent", params}`: A tuple where the second element is the map of
    verification parameters.

  ## Returns
  - The result of the broadcast operation.
  """
  @spec perform({binary(), %{String.t() => any()}}) :: any()
  def perform({"fluent", %{"address_hash" => address_hash} = params}) do
    broadcast(address_hash, params)
  end

  # Broadcasts the verification result to the rest of the application.
  defp broadcast(address_hash, params) do
    # Call the single, unified publish function
    result =
      case Publisher.publish(address_hash, params) do
        {:ok, _contract} = ok_result ->
          ok_result

        {:error, changeset} = error_result ->
          Logger.error(
            "Fluent smart-contract verification for #{inspect(address_hash)} failed with changeset: #{inspect(changeset)}"
          )

          error_result
      end

    Logger.info("Broadcasting Fluent verification results for smart-contract #{inspect(address_hash)}.")

    EventsPublisher.broadcast(
      [{:contract_verification_result, {String.downcase(to_string(address_hash)), result}}],
      :on_demand
    )
  end
end
