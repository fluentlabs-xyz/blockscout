defmodule Indexer.Fetcher.ContractCode do
  @moduledoc """
  Fetches `contract_code` `t:Explorer.Chain.Address.t/0`.
  """

  use Indexer.Fetcher, restart: :permanent
  use Spandex.Decorators

  require Logger

  import EthereumJSONRPC, only: [integer_to_quantity: 1]

  import Explorer.Chain.Transaction.Reader,
    only: [
      transaction_with_unfetched_created_contract_code?: 1,
      stream_transactions_with_unfetched_created_contract_code: 4
    ]

  alias EthereumJSONRPC.Utility.RangesHelper
  alias Explorer.Chain
  alias Explorer.Chain.{Address, Block, Hash, Transaction}
  alias Explorer.Chain.Cache.{Accounts, BlockNumber}
  alias Explorer.Chain.Zilliqa.Helper, as: ZilliqaHelper
  alias Indexer.{BufferedTask, Tracer}
  alias Indexer.Fetcher.CoinBalance.Helper, as: CoinBalanceHelper
  alias Indexer.Fetcher.Zilliqa.ScillaSmartContracts, as: ZilliqaScillaSmartContractsFetcher
  alias Indexer.Transform.Addresses

  @transaction_fields ~w(block_number created_contract_address_hash hash type status)a
  @failed_to_import "failed to import created_contract_code for transactions: "

  @typedoc """
  Represents a list of entries, where each entry is a map containing transaction
  fields required for fetching contract codes.

    - `:block_number` - The block number of the transaction.
    - `:created_contract_address_hash` - The hash of the created contract
      address.
    - `:hash` - The hash of the transaction.
    - `:type` - The type of the transaction.
  """
  @type entry :: %{
          required(:block_number) => Block.block_number(),
          required(:created_contract_address_hash) => Hash.Full.t(),
          required(:hash) => Hash.Full.t(),
          required(:type) => integer(),
          required(:status) => atom()
        }

  @behaviour BufferedTask

  @max_batch_size 10
  @max_concurrency 4
  @defaults [
    flush_interval: :timer.seconds(3),
    max_concurrency: @max_concurrency,
    max_batch_size: @max_batch_size,
    task_supervisor: Indexer.Fetcher.ContractCode.TaskSupervisor,
    metadata: [fetcher: :code]
  ]

  @spec async_fetch([Transaction.t()], boolean(), integer()) :: :ok
  def async_fetch(transactions, realtime?, timeout \\ 5000) when is_list(transactions) do
    transaction_fields =
      transactions
      |> Enum.filter(&transaction_with_unfetched_created_contract_code?(&1))
      |> Enum.map(&Map.take(&1, @transaction_fields))
      |> Enum.uniq()

    BufferedTask.buffer(
      __MODULE__,
      transaction_fields,
      realtime?,
      timeout
    )
  end

  @doc false
  def child_spec([init_options, gen_server_options]) do
    {state, mergeable_init_options} = Keyword.pop(init_options, :json_rpc_named_arguments)

    unless state do
      raise ArgumentError,
            ":json_rpc_named_arguments must be provided to `#{__MODULE__}.child_spec " <>
              "to allow for json_rpc calls when running."
    end

    merged_init_opts =
      @defaults
      |> Keyword.merge(mergeable_init_options)
      |> Keyword.put(:state, state)

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial, reducer, _) do
    if Mix.env() == :test do
      initial
    else
      stream_reducer = RangesHelper.stream_reducer_traceable(reducer)

      {:ok, final} =
        stream_transactions_with_unfetched_created_contract_code(
          @transaction_fields,
          initial,
          stream_reducer,
          true
        )

      final
    end
  end

  @doc """
  Processes a batch of entries to fetch and handle contract code for created
  contracts. This function is executed as part of the `BufferedTask` behavior.

  ## Parameters

    - `entries`: A list of entries to process.
    - `json_rpc_named_arguments`: A list of options for JSON-RPC communication.

  ## Returns

    - `:ok`: Indicates successful processing of the contract codes.
    - `{:retry, any()}`: Returns the entries for retry if an error occurs during
      the fetch operation.
  """
  @impl BufferedTask
  @decorate trace(
              name: "fetch",
              resource: "Indexer.Fetcher.ContractCode.run/2",
              service: :indexer,
              tracer: Tracer
            )
  @spec run([entry()], [
          {:throttle_timeout, non_neg_integer()}
          | {:transport, atom()}
          | {:transport_options, any()}
          | {:variant, atom()}
        ]) :: :ok | {:retry, any()}
  def run(entries, json_rpc_named_arguments) do
    Logger.metadata(fetcher: :code, application: :indexer)
    Logger.info("ContractCode.Fetcher processing #{length(entries)} entries")

    {succeeded, failed} = Enum.split_with(entries, &(&1.status == :ok))

    Logger.debug("Split entries: succeeded=#{length(succeeded)}, failed=#{length(failed)}")

    failed_addresses_params =
      Enum.map(
        failed,
        &%{
          hash: &1.created_contract_address_hash,
          contract_code: "0x"
        }
      )

    with {:ok, succeeded_addresses_params} <- fetch_contract_codes_with_retry(succeeded, json_rpc_named_arguments),
         {:ok, balance_addresses_params} <- fetch_balances(succeeded, json_rpc_named_arguments),
         all_addresses_params =
           Addresses.merge_addresses(succeeded_addresses_params ++ balance_addresses_params) ++ failed_addresses_params,
         {:ok, addresses} <- import_addresses(all_addresses_params) do
      zilliqa_verify_scilla_contracts(succeeded, addresses)
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to fetch contract codes: #{inspect(reason)}", error_count: length(entries))
        {:retry, entries}
    end
  end

  defp fetch_contract_codes_with_retry(entries, json_rpc_args) do
    config = Application.get_env(:indexer, __MODULE__, [])
    max_attempts = Keyword.get(config, :retry_attempts, 5)
    delay_ms = Keyword.get(config, :retry_delay_ms, 800)

    Logger.debug(
      "fetch_contract_codes_with_retry: entries=#{length(entries)}, max_attempts=#{max_attempts}, delay=#{delay_ms}"
    )

    do_retry(entries, json_rpc_args, max_attempts, delay_ms, _attempt = 1)
  end

  defp do_retry(entries, json_rpc_args, max_attempts, delay_ms, attempt) do
    Logger.debug("do_retry: attempt #{attempt}/#{max_attempts}, entries=#{length(entries)}")

    case fetch_contract_codes(entries, json_rpc_args) do
      {:ok, addresses} ->
        Logger.debug("fetch_contract_codes returned #{length(addresses)} addresses")

        {valid, empty} = Enum.split_with(addresses, &has_code?/1)
        Logger.info("Split result: valid=#{length(valid)}, empty=#{length(empty)}")

        handle_fetch_result(valid, empty, entries, json_rpc_args, max_attempts, delay_ms, attempt)

      error ->
        Logger.error("fetch_contract_codes failed: #{inspect(error)}")
        error
    end
  end

  defp handle_fetch_result(valid, [], _entries, _json_rpc_args, _max_attempts, _delay_ms, _attempt) do
    Logger.debug("All codes fetched successfully")
    {:ok, valid}
  end

  defp handle_fetch_result(valid, empty, _entries, _json_rpc_args, max_attempts, _delay_ms, attempt)
       when attempt >= max_attempts do
    Logger.warning("#{length(empty)} contracts still empty after #{max_attempts} attempts")
    Logger.warning("Empty addresses: #{inspect(Enum.map(empty, & &1.hash))}")

    {:ok, valid ++ empty}
  end

  defp handle_fetch_result(valid, empty, entries, json_rpc_args, max_attempts, delay_ms, attempt) do
    Logger.info("Retrying #{length(empty)} empty contracts (attempt #{attempt + 1}/#{max_attempts})")
    Logger.debug("Empty addresses: #{inspect(Enum.map(empty, & &1.hash))}")

    Process.sleep(delay_ms)

    retry_entries = entries_for_addresses(entries, empty)

    Logger.debug("Retry entries prepared: #{length(retry_entries)}")

    case do_retry(retry_entries, json_rpc_args, max_attempts, delay_ms, attempt + 1) do
      {:ok, retried} ->
        Logger.debug("Retry succeeded, merging #{length(retried)} results")
        {:ok, valid ++ retried}

      error ->
        Logger.error("Retry failed: #{inspect(error)}")
        error
    end
  end

  defp has_code?(%{contract_code: code}) do
    code != nil && code != "0x" && String.length(code) > 2
  end

  defp entries_for_addresses(entries, addresses) do
    address_set = MapSet.new(addresses, & &1.hash)

    Enum.filter(entries, fn entry ->
      entry.created_contract_address_hash |> to_string() |> then(&MapSet.member?(address_set, &1))
    end)
  end

  defp fetch_contract_codes([], _), do: {:ok, []}

  defp fetch_contract_codes(entries, json_rpc_args) do
    Logger.debug("fetch_contract_codes: fetching #{length(entries)} entries")

    entries
    |> RangesHelper.filter_traceable_block_numbers()
    |> tap(fn filtered -> Logger.debug("After filter: #{length(filtered)} entries") end)
    |> Enum.map(
      &%{
        block_quantity: integer_to_quantity(&1.block_number),
        address: to_string(&1.created_contract_address_hash)
      }
    )
    |> tap(fn params -> Logger.debug("Prepared RPC params for #{length(params)} addresses") end)
    |> EthereumJSONRPC.fetch_codes(json_rpc_args)
    |> case do
      {:ok, %{params_list: params, errors: []}} ->
        codes = Addresses.extract_addresses(%{codes: params})
        Logger.debug("RPC returned #{length(codes)} codes")
        Logger.debug("Sample codes: #{inspect(Enum.take(codes, 2))}")
        {:ok, codes}

      error ->
        Logger.error("RPC fetch_codes failed: #{inspect(error)}")
        error
    end
  end

  # Fetches balances only for entries
  @spec fetch_balances([entry()], keyword()) ::
          {:ok, [Address.t()]} | {:error, any()}
  defp fetch_balances([], _json_rpc_named_arguments),
    do: {:ok, []}

  defp fetch_balances(entries, json_rpc_named_arguments) do
    entries
    |> Enum.map(
      &%{
        block_quantity: integer_to_quantity(&1.block_number),
        hash_data: to_string(&1.created_contract_address_hash)
      }
    )
    |> EthereumJSONRPC.fetch_balances(json_rpc_named_arguments, BlockNumber.get_max())
    |> case do
      {:ok, fetched_balances} ->
        balance_addresses_params = CoinBalanceHelper.balances_params_to_address_params(fetched_balances.params_list)
        {:ok, balance_addresses_params}

      {:error, reason} ->
        Logger.error(fn -> ["failed to fetch contract balances: ", inspect(reason)] end,
          error_count: Enum.count(entries)
        )

        {:error, reason}
    end
  end

  # Imports addresses into the database
  @spec import_addresses([Address.t()]) ::
          {:ok, [Address.t()]} | {:error, any()}
  defp import_addresses(addresses_params) do
    Logger.debug("Importing #{length(addresses_params)} addresses")
    Logger.debug("Sample addresses to import: #{inspect(Enum.take(addresses_params, 3))}")

    case Chain.import(%{
           addresses: %{params: addresses_params},
           timeout: :infinity
         }) do
      {:ok, %{addresses: addresses}} ->
        Logger.debug("Successfully imported #{length(addresses)} addresses")
        Logger.debug("Sample imported: #{inspect(Enum.take(addresses, 3), limit: :infinity)}")

        Accounts.drop(addresses)
        {:ok, addresses}

      {:error, step, reason, _changes_so_far} ->
        Logger.error(
          fn ->
            [
              @failed_to_import,
              inspect(reason)
            ]
          end,
          step: step
        )

        {:error, reason}

      {:error, reason} ->
        Logger.error(fn ->
          [
            @failed_to_import,
            inspect(reason)
          ]
        end)

        {:error, reason}
    end
  end

  # Filters and verifies Scilla smart contracts for Zilliqa. Contracts are
  # identified from transaction attributes and matched with provided addresses,
  # then processed asynchronously in the separate fetcher.
  @spec zilliqa_verify_scilla_contracts([entry()], [Address.t()]) :: :ok
  defp zilliqa_verify_scilla_contracts(entries, addresses) do
    zilliqa_contract_address_hashes =
      entries
      |> Enum.filter(&(ZilliqaHelper.scilla_transaction?(&1.type) and &1.status == :ok))
      |> MapSet.new(& &1.created_contract_address_hash)

    addresses
    |> Enum.filter(&MapSet.member?(zilliqa_contract_address_hashes, &1.hash))
    |> ZilliqaScillaSmartContractsFetcher.async_fetch(true)
  end
end
