defmodule Indexer.Fetcher.OnDemand.ContractCode do
  @moduledoc """
  Ensures that we have a smart-contract bytecode indexed.
  """

  require Logger

  use GenServer
  use Indexer.Fetcher, restart: :permanent

  import EthereumJSONRPC, only: [fetch_codes: 2]

  alias Explorer.Chain
  alias Explorer.Chain.{Address, Data}
  alias Explorer.Chain.Cache.Counters.Helper
  alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.SmartContract.Proxy.EIP7702
  alias Explorer.Chain.SmartContract.Proxy.Models.Implementation
  alias Explorer.Utility.{AddressContractCodeFetchAttempt, RateLimiter}
  alias Indexer.Fetcher.OnDemand.ContractCreator, as: ContractCreatorOnDemand

  @max_delay :timer.hours(168)

  @spec trigger_fetch(String.t() | nil, Address.t()) :: :ok
  def trigger_fetch(caller \\ nil, address) do
    Logger.metadata(fetcher: :code, application: :indexer)

    Logger.info(
      "[OnDemand] trigger_fetch called: address=#{address.hash}, has_code=#{!is_nil(address.contract_code)}, caller=#{inspect(caller)}"
    )

    if is_nil(address.contract_code) or Address.eoa_with_code?(address) do
      case RateLimiter.check_rate(caller, :on_demand) do
        :allow ->
          Logger.info("[OnDemand] Rate limiter ALLOWED: address=#{address.hash}")
          GenServer.cast(__MODULE__, {:fetch, address})

        :deny ->
          Logger.info("[OnDemand] Rate limiter DENIED: address=#{address.hash}")
          :ok
      end
    else
      Logger.info("[OnDemand] Has code, triggering ContractCreator: address=#{address.hash}")
      ContractCreatorOnDemand.trigger_fetch(address)
    end
  end

  # Attempts to fetch the contract code for a given address.
  #
  # This function checks if the contract code needs to be fetched and if enough time
  # has passed since the last attempt. If conditions are met, it triggers the fetch
  # and broadcast process.
  #
  # ## Parameters
  #   address: The address of the contract.
  #   state: The current state of the fetcher, containing JSON-RPC configuration.
  #
  # ## Returns
  #   `:ok` in all cases.
  @spec fetch_contract_code(Address.t(), %{
          json_rpc_named_arguments: EthereumJSONRPC.json_rpc_named_arguments()
        }) :: :ok
  defp fetch_contract_code(address, state) do
    Logger.metadata(fetcher: :code, application: :indexer)

    with {:need_to_fetch, true} <- {:need_to_fetch, fetch?(address)},
         {:retries_number, {retries_number, updated_at}} <-
           {:retries_number, AddressContractCodeFetchAttempt.get_retries_number(address.hash)},
         updated_at_ms = DateTime.to_unix(updated_at, :millisecond),
         {:retry, true} <-
           {:retry,
            Helper.current_time() - updated_at_ms >
              threshold(retries_number)} do
      Logger.info("[OnDemand] Proceeding to fetch: address=#{address.hash}, retries=#{retries_number}")
      fetch_and_broadcast_bytecode(address, state)
    else
      {:need_to_fetch, false} ->
        Logger.info("[OnDemand] No need to fetch: address=#{address.hash}")
        :ok

      {:retries_number, nil} ->
        Logger.info("[OnDemand] First attempt: address=#{address.hash}")
        fetch_and_broadcast_bytecode(address, state)
        :ok

      {:retry, false} ->
        Logger.info("[OnDemand] Retry timeout not reached: address=#{address.hash}")
        :ok
    end
  end

  # Determines if contract code should be fetched for an address
  @spec fetch?(Address.t()) :: boolean()
  defp fetch?(address) when is_nil(address.nonce), do: true
  # if the address has a signed authorization, it might have a bytecode
  # according to EIP-7702
  defp fetch?(%{signed_authorization: %{authority: _}}), do: true
  defp fetch?(_), do: false

  # Fetches and broadcasts the bytecode for a given address.
  #
  # This function attempts to retrieve the contract bytecode for the specified address
  # using the Ethereum JSON-RPC API. If successful, it updates the database as described below
  # and broadcasts the result:
  # 1. Updates the `addresses` table with the contract code if fetched successfully.
  # 2. Modifies the `address_contract_code_fetch_attempts` table:
  #    - Deletes the entry if the code is successfully set.
  #    - Increments the retry count if the fetch fails or returns empty code.
  # 3. Broadcasts a message with the fetched bytecode if successful.
  #
  # ## Parameters
  #   address_hash: The `t:Explorer.Chain.Hash.Address.t/0` of the contract.
  #   state: The current state of the fetcher, containing JSON-RPC configuration.
  #
  # ## Returns
  #   `:ok` (the function always returns `:ok`, actual results are handled via side effects)
  @spec fetch_and_broadcast_bytecode(Address.t(), %{
          json_rpc_named_arguments: EthereumJSONRPC.json_rpc_named_arguments()
        }) :: :ok
  defp fetch_and_broadcast_bytecode(address, %{json_rpc_named_arguments: _} = state) do
    Logger.metadata(fetcher: :code, application: :indexer)
    Logger.info("[OnDemand] Fetching from node: address=#{address.hash}")

    with {:fetched_code, {:ok, %EthereumJSONRPC.FetchedCodes{params_list: fetched_codes}}} <-
           {:fetched_code,
            fetch_codes(
              [%{block_quantity: "latest", address: to_string(address.hash)}],
              state.json_rpc_named_arguments
            )},
         contract_code_object = List.first(fetched_codes),
         false <- is_nil(contract_code_object),
         {:ok, fetched_code} <-
           (contract_code_object.code == "0x" && {:ok, nil}) || Data.cast(contract_code_object.code),
         true <- fetched_code != address.contract_code do
      code_length = if fetched_code, do: byte_size(fetched_code.bytes), else: 0
      raw_code = contract_code_object.code
      Logger.info("[OnDemand] Fetched: address=#{address.hash}, raw=#{raw_code}, len=#{code_length}")
      Logger.info("[OnDemand] Import params: address=#{address.hash}, len=#{code_length}")

      case Chain.import(%{
             addresses: %{
               params: [%{hash: address.hash, contract_code: fetched_code}],
               on_conflict: {:replace, [:contract_code, :updated_at]},
               fields_to_update: [:contract_code]
             }
           }) do
        {:ok, _} ->
          Logger.info("[OnDemand] Import SUCCESS: address=#{address.hash}, len=#{code_length}")

          cond do
            Address.smart_contract?(address) and !Address.eoa_with_code?(address) ->
              :ok

            is_nil(fetched_code) ->
              Implementation.delete_implementations(address.hash)

            # TODO: it's better to use a generic code like this, but it does unnecessary minimal proxy checks and DB lookups
            # Address.eoa_with_code?(new_address) ->
            #   Proxy.fetch_implementation_address_hash(address.hash, [], [])

            delegate = EIP7702.get_delegate_address(fetched_code.bytes) ->
              Implementation.save_implementation_data([delegate |> to_string()], address.hash, :eip7702, [])

            true ->
              :ok
          end

          Publisher.broadcast(%{fetched_bytecode: [address.hash, contract_code_object.code]}, :on_demand)

          ContractCreatorOnDemand.trigger_fetch(address)

          AddressContractCodeFetchAttempt.delete(address.hash)

        {:error, reason} ->
          Logger.error("[OnDemand] Import FAILED: address=#{address.hash}, reason=#{inspect(reason)}")
      end
    else
      {:fetched_code, {:error, reason}} ->
        Logger.error("[OnDemand] RPC fetch FAILED: address=#{address.hash}, reason=#{inspect(reason)}")
        :ok

      _ ->
        Logger.info("[OnDemand] Incrementing retry counter: address=#{address.hash}")
        AddressContractCodeFetchAttempt.insert_retries_number(address.hash)
    end
  end

  def start_link([init_opts, server_opts]) do
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(json_rpc_named_arguments) do
    {:ok, %{json_rpc_named_arguments: json_rpc_named_arguments}}
  end

  @impl true
  def handle_cast({:fetch, address}, state) do
    Logger.metadata(fetcher: :code, application: :indexer)
    fetch_contract_code(address, state)

    {:noreply, state}
  end

  # An initial threshold to fetch smart-contract bytecode on-demand
  @spec update_threshold_ms() :: non_neg_integer()
  defp update_threshold_ms do
    Application.get_env(:indexer, __MODULE__)[:threshold]
  end

  # Calculates the delay for the next fetch attempt based on the number of retries
  @spec threshold(non_neg_integer()) :: non_neg_integer()
  defp threshold(retries_number) do
    delay_in_ms = trunc(update_threshold_ms() * :math.pow(2, retries_number))

    min(delay_in_ms, @max_delay)
  end
end
