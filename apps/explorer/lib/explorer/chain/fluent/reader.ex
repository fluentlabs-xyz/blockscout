defmodule Explorer.Chain.Fluent.Reader do
  @moduledoc "Contains read functions for Fluent indexer data."

  import Ecto.Query,
    only: [
      from: 2,
      limit: 2,
      order_by: 2,
      where: 2
    ]

  alias Explorer.{Chain, PagingOptions, Repo}
  alias Explorer.Chain.Block
  alias Explorer.Chain.Fluent.{Batch, BatchBundle, Bridge}

  @doc """
  Reads a batch by its number from database.
  """
  @spec batch(non_neg_integer() | :latest, necessity_by_association: %{atom() => :optional | :required}, api?: boolean()) ::
          {:ok, Batch.t()} | {:error, :not_found}
  @spec batch(non_neg_integer() | :latest) :: {:ok, Batch.t()} | {:error, :not_found}
  def batch(number, options \\ [])

  def batch(:latest, options) when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    Batch
    |> order_by(desc: :number)
    |> limit(1)
    |> Chain.join_associations(necessity_by_association)
    |> select_repo(options).one()
    |> case do
      nil -> {:error, :not_found}
      batch -> {:ok, batch}
    end
  end

  def batch(number, options) when is_list(options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})

    Batch
    |> where(number: ^number)
    |> Chain.join_associations(necessity_by_association)
    |> select_repo(options).one()
    |> case do
      nil -> {:error, :not_found}
      batch -> {:ok, batch}
    end
  end

  @spec batches(paging_options: PagingOptions.t(), api?: boolean()) :: [Batch.t()]
  @spec batches() :: [Batch.t()]
  def batches(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())

    case paging_options do
      %PagingOptions{key: {0}} ->
        []

      _ ->
        base_query =
          from(b in Batch,
            order_by: [desc: b.number]
          )

        base_query
        |> Chain.join_association(:bundle, :optional)
        |> page_batches(paging_options)
        |> limit(^paging_options.page_size)
        |> select_repo(options).all()
    end
  end

  @spec batch_blocks(non_neg_integer() | binary(), necessity_by_association: %{atom() => :optional | :required}, api?: boolean(), paging_options: PagingOptions.t()) ::
          [Block.t()]
  def batch_blocks(batch_number, options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())
    api = Keyword.get(options, :api?, false)

    case batch(batch_number, api?: api) do
      {:ok, %{l2_block_range: nil}} ->
        []

      {:ok, batch} ->
        query =
          from(
            b in Block,
            where:
              b.number >= ^batch.l2_block_range.from and b.number <= ^batch.l2_block_range.to and b.consensus == true
          )

        query
        |> page_batch_blocks(paging_options)
        |> limit(^paging_options.page_size)
        |> order_by(desc: :number)
        |> Chain.join_associations(necessity_by_association)
        |> select_repo(options).all()

      _ ->
        []
    end
  end

  @spec batch_by_l2_block_number(non_neg_integer(), keyword()) :: {non_neg_integer(), non_neg_integer() | nil} | nil
  def batch_by_l2_block_number(block_number, options \\ []) do
    select_repo(options).one(
      from(
        b in Batch,
        where: fragment("int8range(?, ?) <@ l2_block_range", ^block_number, ^(block_number + 1)),
        select: {b.number, b.bundle_id}
      )
    )
  end

  @doc """
  Gets last known L1 batch item from the `fluent_batches` table.
  """
  @spec last_l1_batch_item() :: {non_neg_integer(), binary() | nil}
  def last_l1_batch_item do
    query =
      from(b in Batch,
        select: {b.commit_block_number, b.commit_transaction_hash},
        order_by: [desc: b.number],
        limit: 1
      )

    query
    |> Repo.one()
    |> Kernel.||({0, nil})
  end

  @doc """
  Gets `final_batch_number` from the last known L1 bundle.
  """
  @spec last_final_batch_number() :: integer()
  def last_final_batch_number do
    query =
      from(bb in BatchBundle,
        select: bb.final_batch_number,
        order_by: [desc: bb.id],
        limit: 1
      )

    query
    |> Repo.one()
    |> Kernel.||(-1)
  end

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

  defp page_batches(query, %PagingOptions{key: nil}), do: query
  defp page_batches(query, %PagingOptions{key: {number}}), do: from(b in query, where: b.number < ^number)

  defp page_batch_blocks(query, %PagingOptions{key: nil}), do: query
  defp page_batch_blocks(query, %PagingOptions{key: {block_number}}), do: from(b in query, where: b.number < ^block_number)

  defp page_items(query, %PagingOptions{key: nil}), do: query
  defp page_items(query, %PagingOptions{key: {nonce}}), do: from(b in query, where: b.nonce < ^nonce)

  defp select_repo(options), do: Chain.select_repo(options)
end
