defmodule Explorer.SmartContract.Fluent.PublisherWorker do
  @moduledoc """
  Processes Fluent smart contract verification requests asynchronously in the background.

  This module implements a worker that handles verification of Fluent WASM smart contracts
  through their Git repository or archive source code. It uses a job queue system to:
  - Receive verification requests containing contract address and source details
  - Delegate verification to the Publisher module
  - Broadcast verification results through the events system
  """

  require Logger

  use Que.Worker, concurrency: 5

  alias Explorer.Chain.Events.Publisher, as: EventsPublisher
  alias Explorer.SmartContract.Fluent.Publisher

  @doc """
  Processes a Fluent smart contract verification request from a Git repository.

  ## Parameters
  - `{"git_repository", params}`: Tuple containing verification source and parameters

  ## Returns
  - Result of the broadcast operation
  """
  @spec perform({binary(), %{String.t() => any()}}) :: any()
  def perform({"git_repository", %{"address_hash" => address_hash} = params}) do
    broadcast(:publish_git, address_hash, [address_hash, params])
  end

  @doc """
  Processes a Fluent smart contract verification request from a source archive.

  ## Parameters
  - `{"archive", params}`: Tuple containing verification source and parameters

  ## Returns
  - Result of the broadcast operation
  """
  def perform({"archive", %{"address_hash" => address_hash} = params}) do
    broadcast(:publish_archive, address_hash, [address_hash, params])
  end

  # Broadcast verification results
  defp broadcast(method, address_hash, args) do
    result =
      case apply(Publisher, method, args) do
        {:ok, _contract} = result ->
          result

        {:error, changeset} ->
          Logger.error(
            "Fluent smart-contract verification #{address_hash} failed because of the error: #{inspect(changeset)}"
          )

          {:error, changeset}
      end

    Logger.info("Smart-contract #{address_hash} verification: broadcast verification results")

    EventsPublisher.broadcast([{:contract_verification_result, {String.downcase(address_hash), result}}], :on_demand)
  end
end
