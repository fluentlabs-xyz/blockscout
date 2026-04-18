defmodule Explorer.Repo.Migrations.UpdateFluentBridgeEvents do
  use Ecto.Migration

  def up do
    execute("ALTER TYPE fluent_bridge_completion_kind ADD VALUE IF NOT EXISTS 'retried_failed_message'")

    alter table(:fluent_bridge) do
      add(:fee, :numeric, precision: 100)
      add(:valid_until_block_number, :bigint)
    end

    execute("""
    UPDATE fluent_bridge
    SET valid_until_block_number = source_block_number
    WHERE valid_until_block_number IS NULL AND source_block_number IS NOT NULL
    """)
  end

  def down do
    alter table(:fluent_bridge) do
      remove(:fee)
      remove(:valid_until_block_number)
    end

    execute("""
    UPDATE fluent_bridge
    SET completion_kind = 'received_message_rollback'
    WHERE completion_kind::text = 'retried_failed_message'
    """)

    execute("CREATE TYPE fluent_bridge_completion_kind_old AS ENUM ('received_message', 'rollback_message', 'received_message_rollback')")

    execute("""
    ALTER TABLE fluent_bridge
      ALTER COLUMN completion_kind TYPE fluent_bridge_completion_kind_old
      USING completion_kind::text::fluent_bridge_completion_kind_old
    """)

    execute("DROP TYPE fluent_bridge_completion_kind")
    execute("ALTER TYPE fluent_bridge_completion_kind_old RENAME TO fluent_bridge_completion_kind")
  end
end
