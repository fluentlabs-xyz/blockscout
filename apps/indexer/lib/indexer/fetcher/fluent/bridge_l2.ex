defmodule Indexer.Fetcher.Fluent.BridgeL2 do
  @moduledoc """
  Scans Fluent bridge contract logs on L2 and imports correlated bridge operations.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  alias Explorer.Chain.RollupReorgMonitorQueue
  alias Explorer.Chain.Fluent.{Bridge, Reader}
  alias Explorer.Repo
  alias Indexer.Fetcher.Fluent.Bridge, as: BridgeFetcher
  alias Indexer.Helper

  @fetcher_name :fluent_bridge_l2

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(args) do
    json_rpc_named_arguments = args[:json_rpc_named_arguments]
    {:ok, %{}, {:continue, json_rpc_named_arguments}}
  end

  @impl GenServer
  def handle_continue(json_rpc_named_arguments, _state) do
    Logger.metadata(fetcher: @fetcher_name)
    Process.send_after(self(), :init_with_delay, 2000)
    {:noreply, %{json_rpc_named_arguments: json_rpc_named_arguments}}
  end

  @impl GenServer
  def handle_info(:init_with_delay, %{json_rpc_named_arguments: json_rpc_named_arguments} = state) do
    env = Application.get_all_env(:indexer)[__MODULE__]

    with {:bridge_contract_address_is_valid, true} <-
           {:bridge_contract_address_is_valid, Helper.address_correct?(env[:bridge_contract])},
         {last_l2_block_number, last_l2_transaction_hash} = Reader.last_l2_bridge_item(),
         {:ok, block_check_interval, _} <- Helper.get_block_check_interval(json_rpc_named_arguments),
         {:ok, latest_block} <- Helper.get_block_number_by_tag("latest", json_rpc_named_arguments, 100_000_000),
         {:ok, last_l2_transaction} <-
           Helper.get_transaction_by_hash(last_l2_transaction_hash, json_rpc_named_arguments),
         {:l2_transaction_not_found, false} <-
           {:l2_transaction_not_found, !is_nil(last_l2_transaction_hash) && is_nil(last_l2_transaction)} do
      Process.send(self(), :continue, [])

      {:noreply,
       %{
         block_check_interval: block_check_interval,
         bridge_contract: env[:bridge_contract],
         json_rpc_named_arguments: json_rpc_named_arguments,
         end_block: latest_block,
         start_block: max(env[:start_block], last_l2_block_number)
       }}
    else
      {:bridge_contract_address_is_valid, false} ->
        Logger.error("L2 Fluent bridge contract address is invalid or not defined.")
        {:stop, :normal, state}

      {:error, error_data} ->
        Logger.error(
          "Cannot get last L2 transaction from RPC by its hash, latest block, or block by number due to RPC error: #{inspect(error_data)}"
        )

        {:stop, :normal, state}

      {:l2_transaction_not_found, true} ->
        Logger.error(
          "Cannot find last L2 transaction from RPC by its hash. Probably, there was a reorg on L2 chain. Please, check fluent_bridge table."
        )

        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info(:continue, state) do
    BridgeFetcher.loop(__MODULE__, state)
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @spec reorg_handle(non_neg_integer()) :: any()
  def reorg_handle(reorg_block) do
    {deleted_count, _} =
      Repo.delete_all(
        from(b in Bridge,
          where: not is_nil(b.l2_block_number) and b.l2_block_number >= ^reorg_block and is_nil(b.l1_block_number)
        )
      )

    {updated_count, _} =
      Repo.update_all(
        from(b in Bridge,
          where: not is_nil(b.l2_block_number) and b.l2_block_number >= ^reorg_block and not is_nil(b.l1_block_number)
        ),
        set: [l2_transaction_hash: nil, l2_block_number: nil, l2_timestamp: nil]
      )

    {reset_deposit_completion_count, _} =
      Repo.update_all(
        from(b in Bridge,
          where:
            b.type == :deposit and
              not is_nil(b.l2_block_number) and
              b.l2_block_number >= ^reorg_block and
              not is_nil(b.l1_block_number)
        ),
        set: [completion_kind: nil, successful_call: nil, rollback_block_number: nil, return_data: nil]
      )

    total = deleted_count + updated_count + reset_deposit_completion_count

    if total > 0 do
      Logger.warning(
        "As L2 reorg was detected, some records with l2_block_number >= #{reorg_block} were reverted in fluent_bridge table. Affected rows: #{total}."
      )
    end

    RollupReorgMonitorQueue.reorg_block_push(reorg_block, __MODULE__)
  end
end
