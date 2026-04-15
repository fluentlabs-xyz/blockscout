defmodule Explorer.Chain.Fluent.Reader do
  @moduledoc "Contains read functions for Fluent bridge indexer data."

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain
  alias Explorer.Chain.Fluent.Bridge
  alias Explorer.PagingOptions
  alias Explorer.Repo

  @doc """
  Gets the last known L1 bridge item from the `fluent_bridge` table.
  """
  @spec last_l1_bridge_item() :: {non_neg_integer(), binary() | nil}
  def last_l1_bridge_item do
    query =
      from(b in Bridge,
        select: {b.l1_block_number, b.l1_transaction_hash},
        where: not is_nil(b.l1_block_number) and not is_nil(b.l1_transaction_hash),
        order_by: [desc: b.l1_block_number, desc: b.nonce],
        limit: 1
      )

    query
    |> Repo.one()
    |> Kernel.||({0, nil})
  end

  @doc """
  Gets the last known L2 bridge item from the `fluent_bridge` table.
  """
  @spec last_l2_bridge_item() :: {non_neg_integer(), binary() | nil}
  def last_l2_bridge_item do
    query =
      from(b in Bridge,
        select: {b.l2_block_number, b.l2_transaction_hash},
        where: not is_nil(b.l2_block_number) and not is_nil(b.l2_transaction_hash),
        order_by: [desc: b.l2_block_number, desc: b.nonce],
        limit: 1
      )

    query
    |> Repo.one()
    |> Kernel.||({0, nil})
  end

  @spec deposits(paging_options: PagingOptions.t(), api?: boolean()) :: [Bridge.t()]
  @spec deposits() :: [Bridge.t()]
  def deposits(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())

    case paging_options do
      %PagingOptions{key: {0}} ->
        []

      _ ->
        base_query =
          from(
            b in Bridge,
            where:
              b.type == :deposit and
                not is_nil(b.nonce) and
                not is_nil(b.l1_transaction_hash),
            order_by: [desc: b.nonce]
          )

        base_query
        |> page_items(paging_options)
        |> limit(^paging_options.page_size)
        |> select_repo(options).all()
    end
  end

  @spec deposits_count(api?: boolean()) :: non_neg_integer() | nil
  @spec deposits_count() :: non_neg_integer() | nil
  def deposits_count(options \\ []) do
    query =
      from(
        b in Bridge,
        where:
          b.type == :deposit and
            not is_nil(b.nonce) and
            not is_nil(b.l1_transaction_hash)
      )

    select_repo(options).aggregate(query, :count, timeout: :infinity)
  end

  @spec withdrawals(paging_options: PagingOptions.t(), api?: boolean()) :: [Bridge.t()]
  @spec withdrawals() :: [Bridge.t()]
  def withdrawals(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())

    case paging_options do
      %PagingOptions{key: {0}} ->
        []

      _ ->
        base_query =
          from(
            b in Bridge,
            where:
              b.type == :withdrawal and
                not is_nil(b.nonce) and
                not is_nil(b.l2_transaction_hash),
            order_by: [desc: b.nonce]
          )

        base_query
        |> page_items(paging_options)
        |> limit(^paging_options.page_size)
        |> select_repo(options).all()
    end
  end

  @spec withdrawals_count(api?: boolean()) :: non_neg_integer() | nil
  @spec withdrawals_count() :: non_neg_integer() | nil
  def withdrawals_count(options \\ []) do
    query =
      from(
        b in Bridge,
        where:
          b.type == :withdrawal and
            not is_nil(b.nonce) and
            not is_nil(b.l2_transaction_hash)
      )

    select_repo(options).aggregate(query, :count, timeout: :infinity)
  end

  defp page_items(query, %PagingOptions{key: nil}), do: query

  defp page_items(query, %PagingOptions{key: {nonce}}) do
    from(b in query, where: b.nonce < ^nonce)
  end

  defp select_repo(options), do: Chain.select_repo(options)
end
