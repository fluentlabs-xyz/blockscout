defmodule Explorer.Chain.Import.Runner.Fluent.BridgeOperations do
  @moduledoc """
  Bulk imports `Explorer.Chain.Fluent.Bridge`.
  """

  require Ecto.Query

  import Ecto.Query, only: [from: 2]

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.Fluent.Bridge, as: FluentBridge
  alias Explorer.Chain.Import
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [FluentBridge.t()]

  @impl Import.Runner
  def ecto_schema_module, do: FluentBridge

  @impl Import.Runner
  def option_key, do: :fluent_bridge_operations

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[#{ecto_schema_module()}.t()]",
      value_description: "List of `t:#{ecto_schema_module()}.t/0`s"
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    Multi.run(multi, :insert_fluent_bridge_operations, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> insert(repo, changes_list, insert_options) end,
        :block_referencing,
        :fluent_bridge_operations,
        :fluent_bridge_operations
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map()], %{required(:timeout) => timeout(), required(:timestamps) => Import.timestamps()}) ::
          {:ok, [FluentBridge.t()]}
          | {:error, [Changeset.t()]}
  def insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    ordered_changes_list = Enum.sort_by(changes_list, &{&1.type, &1.message_hash})

    {:ok, inserted} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        conflict_target: [:type, :message_hash],
        on_conflict: on_conflict,
        for: FluentBridge,
        returning: true,
        timeout: timeout,
        timestamps: timestamps
      )

    {:ok, inserted}
  end

  defp default_on_conflict do
    from(
      fb in FluentBridge,
      update: [
        set: [
          nonce: fragment("COALESCE(EXCLUDED.nonce, ?)", fb.nonce),
          sender_address_hash: fragment("COALESCE(EXCLUDED.sender_address_hash, ?)", fb.sender_address_hash),
          target_address_hash: fragment("COALESCE(EXCLUDED.target_address_hash, ?)", fb.target_address_hash),
          amount: fragment("COALESCE(EXCLUDED.amount, ?)", fb.amount),
          chain_id: fragment("COALESCE(EXCLUDED.chain_id, ?)", fb.chain_id),
          source_block_number: fragment("COALESCE(EXCLUDED.source_block_number, ?)", fb.source_block_number),
          l1_transaction_hash: fragment("COALESCE(EXCLUDED.l1_transaction_hash, ?)", fb.l1_transaction_hash),
          l1_block_number: fragment("COALESCE(EXCLUDED.l1_block_number, ?)", fb.l1_block_number),
          l1_timestamp: fragment("COALESCE(EXCLUDED.l1_timestamp, ?)", fb.l1_timestamp),
          l2_transaction_hash: fragment("COALESCE(EXCLUDED.l2_transaction_hash, ?)", fb.l2_transaction_hash),
          l2_block_number: fragment("COALESCE(EXCLUDED.l2_block_number, ?)", fb.l2_block_number),
          l2_timestamp: fragment("COALESCE(EXCLUDED.l2_timestamp, ?)", fb.l2_timestamp),
          completion_kind: fragment("COALESCE(EXCLUDED.completion_kind, ?)", fb.completion_kind),
          successful_call: fragment("COALESCE(EXCLUDED.successful_call, ?)", fb.successful_call),
          rollback_block_number: fragment("COALESCE(EXCLUDED.rollback_block_number, ?)", fb.rollback_block_number),
          return_data: fragment("COALESCE(EXCLUDED.return_data, ?)", fb.return_data),
          inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", fb.inserted_at),
          updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", fb.updated_at)
        ]
      ],
      where:
        fragment(
          "(EXCLUDED.nonce, EXCLUDED.sender_address_hash, EXCLUDED.target_address_hash, EXCLUDED.amount, EXCLUDED.chain_id, EXCLUDED.source_block_number, EXCLUDED.l1_transaction_hash, EXCLUDED.l1_block_number, EXCLUDED.l1_timestamp, EXCLUDED.l2_transaction_hash, EXCLUDED.l2_block_number, EXCLUDED.l2_timestamp, EXCLUDED.completion_kind, EXCLUDED.successful_call, EXCLUDED.rollback_block_number, EXCLUDED.return_data) IS DISTINCT FROM (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          fb.nonce,
          fb.sender_address_hash,
          fb.target_address_hash,
          fb.amount,
          fb.chain_id,
          fb.source_block_number,
          fb.l1_transaction_hash,
          fb.l1_block_number,
          fb.l1_timestamp,
          fb.l2_transaction_hash,
          fb.l2_block_number,
          fb.l2_timestamp,
          fb.completion_kind,
          fb.successful_call,
          fb.rollback_block_number,
          fb.return_data
        )
    )
  end
end
