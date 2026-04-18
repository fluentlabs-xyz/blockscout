defmodule Indexer.Fetcher.Fluent.BridgeL1 do
  @moduledoc """
  Scans Fluent bridge contract logs on L1 and imports correlated bridge operations.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  alias Explorer.Chain.Fluent.{Bridge, Reader}
  alias Explorer.Repo
  alias Indexer.Fetcher.Fluent.Bridge, as: BridgeFetcher
  alias Indexer.Fetcher.RollupL1ReorgMonitor
  alias Indexer.Helper

  @fetcher_name :fluent_bridge_l1

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
  def init(_args) do
    {:ok, %{}, {:continue, :ok}}
  end

  @impl GenServer
  def handle_continue(_, state) do
    Logger.metadata(fetcher: @fetcher_name)
    Process.send_after(self(), :init_with_delay, 2000)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:init_with_delay, _state) do
    env = Application.get_all_env(:indexer)[__MODULE__]

    with {:start_block_undefined, false} <- {:start_block_undefined, is_nil(env[:start_block])},
         _ <- RollupL1ReorgMonitor.wait_for_start(__MODULE__),
         rpc = l1_rpc_url(),
         {:rpc_undefined, false} <- {:rpc_undefined, is_nil(rpc)},
         {:bridge_contract_address_is_valid, true} <-
           {:bridge_contract_address_is_valid, Helper.address_correct?(env[:bridge_contract])},
         start_block = env[:start_block],
         true <- start_block > 0,
         {last_l1_block_number, last_l1_transaction_hash} = Reader.last_l1_bridge_item(),
         json_rpc_named_arguments = Helper.json_rpc_named_arguments(rpc),
         {:ok, block_check_interval, safe_block} <- Helper.get_block_check_interval(json_rpc_named_arguments),
         {:start_block_valid, true, _, _} <-
           {:start_block_valid,
            (start_block <= last_l1_block_number || last_l1_block_number == 0) && start_block <= safe_block,
            last_l1_block_number, safe_block},
         {:ok, last_l1_transaction} <-
           Helper.get_transaction_by_hash(last_l1_transaction_hash, json_rpc_named_arguments),
         {:l1_transaction_not_found, false} <-
           {:l1_transaction_not_found, !is_nil(last_l1_transaction_hash) && is_nil(last_l1_transaction)} do
      Process.send(self(), :continue, [])

      {:noreply,
       %{
         block_check_interval: block_check_interval,
         bridge_contract: env[:bridge_contract],
         json_rpc_named_arguments: json_rpc_named_arguments,
         end_block: safe_block,
         start_block: max(start_block, last_l1_block_number)
       }}
    else
      {:start_block_undefined, true} ->
        {:stop, :normal, %{}}

      {:rpc_undefined, true} ->
        Logger.error("L1 RPC URL is not defined.")
        {:stop, :normal, %{}}

      {:bridge_contract_address_is_valid, false} ->
        Logger.error("L1 Fluent bridge contract address is invalid or not defined.")
        {:stop, :normal, %{}}

      {:start_block_valid, false, last_l1_block_number, safe_block} ->
        Logger.error("Invalid L1 Start Block value. Please, check the value and fluent_bridge table.")
        Logger.error("last_l1_block_number = #{inspect(last_l1_block_number)}")
        Logger.error("safe_block = #{inspect(safe_block)}")
        {:stop, :normal, %{}}

      {:error, error_data} ->
        Logger.error(
          "Cannot get last L1 transaction from RPC by its hash, latest block, or block timestamp by its number due to RPC error: #{inspect(error_data)}"
        )

        {:stop, :normal, %{}}

      {:l1_transaction_not_found, true} ->
        Logger.error(
          "Cannot find last L1 transaction from RPC by its hash. Probably, there was a reorg on L1 chain. Please, check fluent_bridge table."
        )

        {:stop, :normal, %{}}

      _ ->
        Logger.error("L1 Start Block is invalid or zero.")
        {:stop, :normal, %{}}
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
          where: not is_nil(b.l1_block_number) and b.l1_block_number >= ^reorg_block and is_nil(b.l2_block_number)
        )
      )

    {updated_count, _} =
      Repo.update_all(
        from(b in Bridge,
          where: not is_nil(b.l1_block_number) and b.l1_block_number >= ^reorg_block and not is_nil(b.l2_block_number)
        ),
        set: [l1_transaction_hash: nil, l1_block_number: nil, l1_timestamp: nil]
      )

    {reset_withdrawal_completion_count, _} =
      Repo.update_all(
        from(b in Bridge,
          where:
            b.type == :withdrawal and
              not is_nil(b.l1_block_number) and
              b.l1_block_number >= ^reorg_block and
              not is_nil(b.l2_block_number)
        ),
        set: [completion_kind: nil, successful_call: nil, rollback_block_number: nil, return_data: nil]
      )

    total = deleted_count + updated_count + reset_withdrawal_completion_count

    if total > 0 do
      Logger.warning(
        "As L1 reorg was detected, some records with l1_block_number >= #{reorg_block} were reverted in fluent_bridge table. Affected rows: #{total}."
      )
    end
  end

  @spec l1_rpc_url() :: binary() | nil
  def l1_rpc_url do
    Application.get_all_env(:indexer)[Indexer.Fetcher.Fluent][:rpc]
  end

  @spec requires_l1_reorg_monitor?() :: boolean()
  def requires_l1_reorg_monitor? do
    module_config = Application.get_all_env(:indexer)[__MODULE__]
    not is_nil(module_config[:start_block])
  end
end
