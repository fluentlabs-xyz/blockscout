defmodule Explorer.Chain.Fluent.Bridge do
  @moduledoc "Models Fluent bridge operation."

  use Explorer.Schema

  alias Explorer.Chain.Hash

  @optional_attrs ~w(
    nonce
    sender_address_hash
    target_address_hash
    amount
    chain_id
    source_block_number
    l1_transaction_hash
    l1_block_number
    l1_timestamp
    l2_transaction_hash
    l2_block_number
    l2_timestamp
    completion_kind
    successful_call
    rollback_block_number
    return_data
  )a

  @required_attrs ~w(type message_hash)a
  @allowed_attrs @required_attrs ++ @optional_attrs

  @type to_import :: %{
          type: :deposit | :withdrawal,
          message_hash: binary(),
          nonce: non_neg_integer() | nil,
          sender_address_hash: binary() | nil,
          target_address_hash: binary() | nil,
          amount: Decimal.t() | non_neg_integer() | nil,
          chain_id: Decimal.t() | non_neg_integer() | nil,
          source_block_number: non_neg_integer() | nil,
          l1_transaction_hash: binary() | nil,
          l1_block_number: non_neg_integer() | nil,
          l1_timestamp: DateTime.t() | nil,
          l2_transaction_hash: binary() | nil,
          l2_block_number: non_neg_integer() | nil,
          l2_timestamp: DateTime.t() | nil,
          completion_kind: :received_message | :rollback_message | :received_message_rollback | nil,
          successful_call: boolean() | nil,
          rollback_block_number: non_neg_integer() | nil,
          return_data: binary() | nil
        }

  @primary_key false
  typed_schema "fluent_bridge" do
    field(:type, Ecto.Enum, values: [:deposit, :withdrawal], primary_key: true)
    field(:message_hash, Hash.Full, primary_key: true)

    field(:nonce, :integer)
    field(:sender_address_hash, Hash.Address)
    field(:target_address_hash, Hash.Address)
    field(:amount, :decimal)
    field(:chain_id, :decimal)
    field(:source_block_number, :integer)

    field(:l1_transaction_hash, Hash.Full)
    field(:l1_block_number, :integer)
    field(:l1_timestamp, :utc_datetime_usec)

    field(:l2_transaction_hash, Hash.Full)
    field(:l2_block_number, :integer)
    field(:l2_timestamp, :utc_datetime_usec)

    field(:completion_kind, Ecto.Enum, values: [:received_message, :rollback_message, :received_message_rollback])
    field(:successful_call, :boolean)
    field(:rollback_block_number, :integer)
    field(:return_data, :binary)

    timestamps()
  end

  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def changeset(%__MODULE__{} = bridge_operation, attrs \\ %{}) do
    bridge_operation
    |> cast(attrs, @allowed_attrs)
    |> validate_required(@required_attrs)
    |> unique_constraint([:type, :message_hash])
  end
end
