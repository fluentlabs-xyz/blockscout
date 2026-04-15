defmodule Explorer.Repo.Migrations.AddFluentBatchesTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE fluent_da_containers_types AS ENUM ('in_blob4844', 'in_calldata')",
      "DROP TYPE fluent_da_containers_types"
    )

    create table(:fluent_batch_bundles, primary_key: true) do
      add(:final_batch_number, :bigint, null: false)
      add(:finalize_transaction_hash, :bytea, null: false)
      add(:finalize_block_number, :bigint, null: false)
      add(:finalize_timestamp, :"timestamp without time zone", null: false)
      timestamps(null: false, type: :utc_datetime_usec)
    end

    create table(:fluent_batches, primary_key: false) do
      add(:number, :bigint, primary_key: true)
      add(:commit_transaction_hash, :bytea, null: false)
      add(:commit_block_number, :bigint, null: false)
      add(:commit_timestamp, :"timestamp without time zone", null: false)

      add(
        :bundle_id,
        references(:fluent_batch_bundles, on_delete: :restrict, on_update: :update_all, type: :bigint),
        null: true,
        default: nil
      )

      add(:l2_block_range, :int8range)
      add(:container, :fluent_da_containers_types, null: false)
      timestamps(null: false, type: :utc_datetime_usec)
    end

    create(index(:fluent_batch_bundles, :finalize_block_number))
    create(index(:fluent_batches, :commit_block_number))
    create(index(:fluent_batches, :l2_block_range))
  end
end
