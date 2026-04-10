defmodule Explorer.Repo.Migrations.AddFluentFields do
  use Ecto.Migration

  def change do
    alter table(:smart_contracts) do
      add(:package_name, :string, null: true)
      add(:fluent_metadata, :jsonb, null: true)
    end

    create(index(:smart_contracts, [:package_name]))
  end
end
