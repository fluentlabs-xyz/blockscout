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

    Initiates the verification process by broadcasting the verification request to
    the module responsible for the actual verification and consequent update of
    the database. This function is called automatically by the job queue system.

    ## Parameters
    - `{"git_repository", params}`: Tuple containing:
      - First element: `"git_repository"` indicating the verification source
      - Second element: Map containing:
        - `"address_hash"`: The contract's address hash to verify
        - Other verification parameters for Git source

    ## Returns
    - Result of the broadcast operation
  """
  @spec perform({binary(), %{String.t() => any()}}) :: any()
  def perform({"git_repository", %{"address_hash" => address_hash} = params}) do
    broadcast(:publish_git, address_hash, [address_hash, params])
  end

  @doc """
    Processes a Fluent smart contract verification request from a source archive.

    Initiates the verification process by broadcasting the verification request to
    the module responsible for the actual verification and consequent update of
    the database. This function is called automatically by the job queue system.

    ## Parameters
    - `{"archive", params}`: Tuple containing:
      - First element: `"archive"` indicating the verification source
      - Second element: Map containing:
        - `"address_hash"`: The contract's address hash to verify
        - Other verification parameters for archive source

    ## Returns
    - Result of the broadcast operation
  """
  def perform({"archive", %{"address_hash" => address_hash} = params}) do
    broadcast(:publish_archive, address_hash, [address_hash, params])
  end

  # Broadcasts the result of a Fluent smart contract verification attempt.
  #
  # Executes the specified verification method in the `Publisher` module and
  # broadcasts the result through the events publisher.
  #
  # ## Parameters
  # - `method`: The verification method to execute (`:publish_git` or `:publish_archive`)
  # - `address_hash`: Contract address
  # - `args`: Arguments to pass to the verification method
  #
  # ## Returns
  # - `{:ok, contract}` if verification succeeds
  # - `{:error, changeset}` if verification fails
  @spec broadcast(atom(), binary() | Explorer.Chain.Hash.t(), any()) :: any()
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
