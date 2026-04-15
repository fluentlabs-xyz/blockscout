defmodule BlockScoutWeb.API.V2.FluentView do
  use BlockScoutWeb, :view

  alias Explorer.Chain.Transaction
  alias Explorer.Chain.Fluent.Batch

  @spec render(binary(), map()) :: map() | non_neg_integer()
  def render("fluent_bridge_items.json", %{items: items, next_page_params: next_page_params, type: type}) do
    %{
      items:
        Enum.map(items, fn item ->
          {origination_transaction_hash, origination_block_number, origination_timestamp, completion_transaction_hash,
           completion_block_number, completion_timestamp} =
            if type == :deposits do
              {
                item.l1_transaction_hash,
                item.l1_block_number,
                item.l1_timestamp,
                item.l2_transaction_hash,
                item.l2_block_number,
                item.l2_timestamp
              }
            else
              {
                item.l2_transaction_hash,
                item.l2_block_number,
                item.l2_timestamp,
                item.l1_transaction_hash,
                item.l1_block_number,
                item.l1_timestamp
              }
            end

          %{
            "id" => item.nonce,
            "message_hash" => item.message_hash,
            "origination_transaction_hash" => origination_transaction_hash,
            "origination_timestamp" => origination_timestamp,
            "origination_transaction_block_number" => origination_block_number,
            "completion_transaction_hash" => completion_transaction_hash,
            "completion_timestamp" => completion_timestamp,
            "completion_transaction_block_number" => completion_block_number,
            "completion_kind" => item.completion_kind,
            "successful_call" => item.successful_call,
            "rollback_block_number" => item.rollback_block_number,
            "value" => item.amount,
            "sender_address_hash" => item.sender_address_hash,
            "target_address_hash" => item.target_address_hash,
            "chain_id" => item.chain_id,
            "source_block_number" => item.source_block_number,
            "status" => operation_status(item)
          }
        end),
      next_page_params: next_page_params
    }
  end

  def render("fluent_bridge_items_count.json", %{count: count}), do: count

  def render("fluent_batch.json", %{batch: batch}) do
    render_batch(batch)
  end

  def render("fluent_batches.json", %{batches: batches, next_page_params: next_page_params}) do
    items =
      batches
      |> Enum.map(fn batch ->
        Task.async(fn -> render_batch(batch) end)
      end)
      |> Task.yield_many(:infinity)
      |> Enum.map(fn {_task, {:ok, item}} -> item end)

    %{
      items: items,
      next_page_params: next_page_params
    }
  end

  def render("fluent_batches_count.json", %{count: count}), do: count

  @spec render_batch(Batch.t()) :: map()
  defp render_batch(batch) do
    {finalize_block_number, finalize_transaction_hash, finalize_timestamp} =
      if is_nil(batch.bundle) do
        {nil, nil, nil}
      else
        {batch.bundle.finalize_block_number, batch.bundle.finalize_transaction_hash, batch.bundle.finalize_timestamp}
      end

    {start_block_number, end_block_number, transactions_count} =
      if is_nil(batch.l2_block_range) do
        {nil, nil, nil}
      else
        {
          batch.l2_block_range.from,
          batch.l2_block_range.to,
          Transaction.transaction_count_for_block_range(batch.l2_block_range.from..batch.l2_block_range.to)
        }
      end

    %{
      "number" => batch.number,
      "commitment_transaction" => %{
        "block_number" => batch.commit_block_number,
        "hash" => batch.commit_transaction_hash,
        "timestamp" => batch.commit_timestamp
      },
      "confirmation_transaction" => %{
        "block_number" => finalize_block_number,
        "hash" => finalize_transaction_hash,
        "timestamp" => finalize_timestamp
      },
      "data_availability" => %{
        "batch_data_container" => batch.container
      },
      "start_block_number" => start_block_number,
      "end_block_number" => end_block_number,
      "transactions_count" => transactions_count
    }
  end

  defp operation_status(item) do
    cond do
      item.completion_kind == :rollback_message -> "rollback"
      is_nil(item.l1_transaction_hash) or is_nil(item.l2_transaction_hash) -> "pending"
      true -> "completed"
    end
  end
end
