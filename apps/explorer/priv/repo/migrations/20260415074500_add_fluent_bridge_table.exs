defmodule Explorer.Repo.Migrations.AddFluentBridgeTable do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE fluent_bridge_op_type AS ENUM ('deposit', 'withdrawal')",
      "DROP TYPE fluent_bridge_op_type"
    )

    execute(
      "CREATE TYPE fluent_bridge_completion_kind AS ENUM ('received_message', 'rollback_message', 'received_message_rollback')",
      "DROP TYPE fluent_bridge_completion_kind"
    )

    create table(:fluent_bridge, primary_key: false) do
      add(:type, :fluent_bridge_op_type, null: false, primary_key: true)
      add(:message_hash, :bytea, null: false, primary_key: true)

      add(:nonce, :bigint)
      add(:sender_address_hash, :bytea)
      add(:target_address_hash, :bytea)
      add(:amount, :numeric, precision: 100)
      add(:chain_id, :numeric, precision: 100)
      add(:source_block_number, :bigint)

      add(:l1_transaction_hash, :bytea)
      add(:l1_block_number, :bigint)
      add(:l1_timestamp, :utc_datetime_usec)

      add(:l2_transaction_hash, :bytea)
      add(:l2_block_number, :bigint)
      add(:l2_timestamp, :utc_datetime_usec)

      add(:completion_kind, :fluent_bridge_completion_kind)
      add(:successful_call, :boolean)
      add(:rollback_block_number, :bigint)
      add(:return_data, :bytea)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    create(index(:fluent_bridge, [:type, :nonce]))
    create(index(:fluent_bridge, [:l1_block_number]))
    create(index(:fluent_bridge, [:l2_block_number]))
    create(index(:fluent_bridge, [:l1_transaction_hash]))
    create(index(:fluent_bridge, [:l2_transaction_hash]))
  end
end
