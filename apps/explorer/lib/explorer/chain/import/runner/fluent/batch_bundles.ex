defmodule Explorer.Chain.Import.Runner.Fluent.BatchBundles do
  @moduledoc """
  Bulk imports `Explorer.Chain.Fluent.BatchBundle`.
  """

  require Ecto.Query

  import Ecto.Query, only: [from: 2]

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.Import
  alias Explorer.Chain.Fluent.BatchBundle, as: FluentBatchBundle
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [FluentBatchBundle.t()]

  @impl Import.Runner
  def ecto_schema_module, do: FluentBatchBundle

  @impl Import.Runner
  def option_key, do: :fluent_batch_bundles

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

    Multi.run(multi, :insert_fluent_batch_bundles, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> insert(repo, changes_list, insert_options) end,
        :block_referencing,
        :fluent_batch_bundles,
        :fluent_batch_bundles
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map()], %{required(:timeout) => timeout(), required(:timestamps) => Import.timestamps()}) ::
          {:ok, [FluentBatchBundle.t()]}
          | {:error, [Changeset.t()]}
  def insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    # Enforce FluentBatchBundle ShareLocks order (see docs: sharelock.md)
    ordered_changes_list = Enum.sort_by(changes_list, & &1.final_batch_number)

    {:ok, inserted} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        conflict_target: :id,
        on_conflict: on_conflict,
        for: FluentBatchBundle,
        returning: true,
        timeout: timeout,
        timestamps: timestamps
      )

    {:ok, inserted}
  end

  defp default_on_conflict do
    from(
      sbb in FluentBatchBundle,
      update: [
        set: [
          # Don't update `id` as it is a primary key and used for the conflict target
          final_batch_number: fragment("EXCLUDED.final_batch_number"),
          finalize_transaction_hash: fragment("EXCLUDED.finalize_transaction_hash"),
          finalize_block_number: fragment("EXCLUDED.finalize_block_number"),
          finalize_timestamp: fragment("EXCLUDED.finalize_timestamp"),
          inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", sbb.inserted_at),
          updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", sbb.updated_at)
        ]
      ],
      where:
        fragment(
          "(EXCLUDED.final_batch_number, EXCLUDED.finalize_transaction_hash, EXCLUDED.finalize_block_number, EXCLUDED.finalize_timestamp) IS DISTINCT FROM (?, ?, ?, ?)",
          sbb.final_batch_number,
          sbb.finalize_transaction_hash,
          sbb.finalize_block_number,
          sbb.finalize_timestamp
        )
    )
  end
end
