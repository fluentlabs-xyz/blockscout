defmodule Indexer.Fetcher.Fluent.Bridge do
  @moduledoc """
  Contains common functions for Indexer.Fetcher.Fluent.Bridge* modules.
  """

  require Logger

  import EthereumJSONRPC,
    only: [
      quantity_to_integer: 1,
      timestamp_to_datetime: 1
    ]

  import Explorer.Helper, only: [decode_data: 2]

  alias EthereumJSONRPC.Logs
  alias Explorer.Chain
  alias Explorer.Chain.RollupReorgMonitorQueue
  alias Indexer.Fetcher.Fluent.BridgeL1
  alias Indexer.Helper, as: IndexerHelper

  @sent_message_event
    "0x" <>
      Base.encode16(
        ExKeccak.hash_256("SentMessage(address,address,uint256,uint256,uint256,uint256,uint256,bytes32,bytes)"),
        case: :lower
      )

  @legacy_sent_message_event
    "0x" <>
      Base.encode16(
        ExKeccak.hash_256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)"),
        case: :lower
      )

  @received_message_event "0xc5797c3a3c0e6c245576d05b8c3929881b44e1a21fdb4f1b118ede3c009683c5"
  @rollback_message_event "0x" <> Base.encode16(ExKeccak.hash_256("RollbackMessage(bytes32,uint256)"), case: :lower)
  @retried_failed_message_event
    "0x" <> Base.encode16(ExKeccak.hash_256("RetriedFailedMessage(bytes32,bool,bytes)"), case: :lower)

  @received_message_rollback_event
    "0x" <> Base.encode16(ExKeccak.hash_256("ReceivedMessageRollback(bytes32,bool,bytes)"), case: :lower)

  @supported_events [
    @sent_message_event,
    @legacy_sent_message_event,
    @received_message_event,
    @rollback_message_event,
    @retried_failed_message_event,
    @received_message_rollback_event
  ]

  @sent_message_event_params [
    {:uint, 256},
    {:uint, 256},
    {:uint, 256},
    {:uint, 256},
    {:uint, 256},
    {:bytes, 32},
    :bytes
  ]

  @legacy_sent_message_event_params [{:uint, 256}, {:uint, 256}, {:uint, 256}, {:uint, 256}, {:bytes, 32}, :bytes]

  @spec loop(module(), %{
          block_check_interval: non_neg_integer(),
          bridge_contract: binary(),
          json_rpc_named_arguments: EthereumJSONRPC.json_rpc_named_arguments(),
          end_block: non_neg_integer(),
          start_block: non_neg_integer()
        }) ::
          {:noreply,
           %{
             block_check_interval: non_neg_integer(),
             bridge_contract: binary(),
             json_rpc_named_arguments: EthereumJSONRPC.json_rpc_named_arguments(),
             end_block: non_neg_integer(),
             start_block: non_neg_integer()
           }}
  def loop(
        module,
        %{
          block_check_interval: block_check_interval,
          bridge_contract: bridge_contract,
          json_rpc_named_arguments: json_rpc_named_arguments,
          end_block: end_block,
          start_block: start_block
        } = state
      ) do
    {layer, eth_get_logs_range_size_config} =
      if module == BridgeL1 do
        {:L1, :l1_eth_get_logs_range_size}
      else
        {:L2, :l2_eth_get_logs_range_size}
      end

    eth_get_logs_range_size = Application.get_all_env(:indexer)[Indexer.Fetcher.Fluent][eth_get_logs_range_size_config]

    time_before = Timex.now()

    block_range = if(start_block <= end_block, do: start_block..end_block, else: [])

    last_written_block =
      block_range
      |> Enum.chunk_every(eth_get_logs_range_size)
      |> Enum.reduce_while(start_block - 1, fn current_chunk, _ ->
        chunk_start = List.first(current_chunk)
        chunk_end = List.last(current_chunk)

        if chunk_start <= chunk_end do
          IndexerHelper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block, end_block, nil, layer)

          operations =
            {chunk_start, chunk_end}
            |> get_logs_all(bridge_contract, json_rpc_named_arguments)
            |> prepare_operations(layer == :L1, json_rpc_named_arguments)

          import_operations(operations)

          IndexerHelper.log_blocks_chunk_handling(
            chunk_start,
            chunk_end,
            start_block,
            end_block,
            "#{Enum.count(operations)} #{layer} operation(s)",
            layer
          )
        end

        reorg_block = RollupReorgMonitorQueue.reorg_block_pop(module)

        if !is_nil(reorg_block) && reorg_block > 0 do
          if layer == :L1 do
            BridgeL1.reorg_handle(reorg_block)
          end

          {:halt, if(reorg_block <= chunk_end, do: reorg_block - 1, else: chunk_end)}
        else
          {:cont, chunk_end}
        end
      end)

    new_start_block = last_written_block + 1

    {:ok, new_end_block} =
      IndexerHelper.get_block_number_by_tag("latest", json_rpc_named_arguments, IndexerHelper.infinite_retries_number())

    delay =
      if new_end_block < new_start_block do
        max(block_check_interval - Timex.diff(Timex.now(), time_before, :milliseconds), 0)
      else
        0
      end

    Process.send_after(Process.whereis(module), :continue, delay)

    {:noreply, %{state | start_block: new_start_block, end_block: new_end_block}}
  end

  @spec get_logs_all({non_neg_integer(), non_neg_integer()}, binary(), EthereumJSONRPC.json_rpc_named_arguments()) ::
          [%{atom() => any()}]
  defp get_logs_all({chunk_start, chunk_end}, bridge_contract, json_rpc_named_arguments) do
    {:ok, result} =
      IndexerHelper.get_logs(
        chunk_start,
        chunk_end,
        bridge_contract,
        [@supported_events],
        json_rpc_named_arguments,
        0,
        IndexerHelper.infinite_retries_number()
      )

    Logs.elixir_to_params(result)
  end

  @spec import_operations([Explorer.Chain.Fluent.Bridge.to_import()]) :: any()
  defp import_operations([]), do: :ok

  defp import_operations(operations) do
    {:ok, _} =
      Chain.import(%{
        fluent_bridge_operations: %{params: operations},
        timeout: :infinity
      })
  end

  @spec prepare_operations([%{atom() => any()}], boolean(), EthereumJSONRPC.json_rpc_named_arguments()) ::
          [Explorer.Chain.Fluent.Bridge.to_import()]
  defp prepare_operations(events, is_l1, json_rpc_named_arguments) do
    supported_events = Enum.filter(events, &(&1.first_topic in @supported_events))

    block_to_timestamp = blocks_to_timestamps(supported_events, json_rpc_named_arguments)

    supported_events
    |> Enum.map(fn event ->
      topic = event.first_topic
      block_number = quantity_to_integer(event.block_number)
      block_timestamp = Map.get(block_to_timestamp, block_number)

      operation_type = operation_type(topic, is_l1)

      base =
        %{
          type: operation_type
        }
        |> put_layer_fields(is_l1, event.transaction_hash, block_number, block_timestamp)

      case topic do
        topic when topic in [@sent_message_event, @legacy_sent_message_event] ->
          sent_message = sent_message_event_parse(event)

          base
          |> Map.put(:message_hash, sent_message.message_hash)
          |> Map.put(:nonce, sent_message.nonce)
          |> Map.put(:sender_address_hash, sent_message.sender)
          |> Map.put(:target_address_hash, sent_message.target)
          |> Map.put(:amount, sent_message.value)
          |> Map.put(:fee, sent_message.fee)
          |> Map.put(:chain_id, sent_message.chain_id)
          |> Map.put(:valid_until_block_number, sent_message.valid_until_block_number)
          |> Map.put(:source_block_number, sent_message.source_block_number)

        @received_message_event ->
          received_message = decode_bridge_received_message(event.data)

          base
          |> Map.put(:message_hash, received_message.message_hash)
          |> Map.put(:completion_kind, :received_message)
          |> extend_result(:successful_call, received_message.successful_call)
          |> extend_result(:return_data, received_message.return_data)

        @rollback_message_event ->
          rollback_message = decode_bridge_rollback_message(event.data)

          base
          |> Map.put(:message_hash, rollback_message.message_hash)
          |> Map.put(:completion_kind, :rollback_message)
          |> extend_result(:rollback_block_number, rollback_message.rollback_block_number)

        @retried_failed_message_event ->
          retried_failed_message = decode_bridge_received_message(event.data)

          base
          |> Map.put(:message_hash, retried_failed_message.message_hash)
          |> Map.put(:completion_kind, :retried_failed_message)
          |> extend_result(:successful_call, retried_failed_message.successful_call)
          |> extend_result(:return_data, retried_failed_message.return_data)

        @received_message_rollback_event ->
          received_message_rollback = decode_bridge_received_message(event.data)

          base
          |> Map.put(:message_hash, received_message_rollback.message_hash)
          |> Map.put(:completion_kind, :received_message_rollback)
          |> extend_result(:successful_call, received_message_rollback.successful_call)
          |> extend_result(:return_data, received_message_rollback.return_data)

        _ ->
          nil
      end
    end)
    |> Enum.reject(&(is_nil(&1) or is_nil(&1.message_hash)))
  end

  @spec blocks_to_timestamps([%{atom() => any()}], EthereumJSONRPC.json_rpc_named_arguments()) ::
          %{non_neg_integer() => DateTime.t()}
  defp blocks_to_timestamps(events, json_rpc_named_arguments) do
    events
    |> IndexerHelper.get_blocks_by_events(json_rpc_named_arguments, IndexerHelper.infinite_retries_number())
    |> Enum.reduce(%{}, fn block, acc ->
      block_number = quantity_to_integer(Map.get(block, "number"))
      timestamp = timestamp_to_datetime(Map.get(block, "timestamp"))
      Map.put(acc, block_number, timestamp)
    end)
  end

  defp sent_message_event_parse(%{first_topic: @sent_message_event} = event) do
    [value, fee, chain_id, valid_until_block_number, nonce, message_hash, _message_data] =
      decode_data(event.data, @sent_message_event_params)

    %{
      sender: decode_topic_address(event.second_topic),
      target: decode_topic_address(event.third_topic),
      value: value,
      fee: fee,
      chain_id: chain_id,
      valid_until_block_number: valid_until_block_number,
      source_block_number: valid_until_block_number,
      nonce: nonce,
      message_hash: bytes32_to_hash(message_hash)
    }
  end

  defp sent_message_event_parse(event) do
    [value, chain_id, source_block_number, nonce, message_hash, _message_data] =
      decode_data(event.data, @legacy_sent_message_event_params)

    %{
      sender: decode_topic_address(event.second_topic),
      target: decode_topic_address(event.third_topic),
      value: value,
      fee: nil,
      chain_id: chain_id,
      valid_until_block_number: source_block_number,
      source_block_number: source_block_number,
      nonce: nonce,
      message_hash: bytes32_to_hash(message_hash)
    }
  end

  @spec decode_bridge_received_message(binary() | nil) :: %{message_hash: binary() | nil, successful_call: boolean() | nil, return_data: binary() | nil}
  defp decode_bridge_received_message(data) do
    with {:ok, bytes} <- decode_data_hex(data),
         true <- byte_size(bytes) >= 96 do
      %{
        message_hash: decode_word_as_hash(bytes, 0),
        successful_call: decode_word(bytes, 32) == 1,
        return_data: decode_dynamic_bytes(bytes, 64)
      }
    else
      _ -> %{message_hash: nil, successful_call: nil, return_data: nil}
    end
  end

  @spec decode_bridge_rollback_message(binary() | nil) :: %{message_hash: binary() | nil, rollback_block_number: non_neg_integer() | nil}
  defp decode_bridge_rollback_message(data) do
    with {:ok, bytes} <- decode_data_hex(data),
         true <- byte_size(bytes) >= 64 do
      %{
        message_hash: decode_word_as_hash(bytes, 0),
        rollback_block_number: decode_word(bytes, 32)
      }
    else
      _ -> %{message_hash: nil, rollback_block_number: nil}
    end
  end

  defp operation_type(topic, true) when topic in [@sent_message_event, @legacy_sent_message_event], do: :deposit
  defp operation_type(topic, false) when topic in [@sent_message_event, @legacy_sent_message_event], do: :withdrawal
  defp operation_type(_event, true), do: :withdrawal
  defp operation_type(_event, false), do: :deposit

  defp put_layer_fields(result, true, transaction_hash, block_number, block_timestamp) do
    result
    |> Map.put(:l1_transaction_hash, transaction_hash)
    |> Map.put(:l1_block_number, block_number)
    |> Map.put(:l1_timestamp, block_timestamp)
  end

  defp put_layer_fields(result, false, transaction_hash, block_number, block_timestamp) do
    result
    |> Map.put(:l2_transaction_hash, transaction_hash)
    |> Map.put(:l2_block_number, block_number)
    |> Map.put(:l2_timestamp, block_timestamp)
  end

  defp decode_data_hex("0x" <> data_hex), do: Base.decode16(data_hex, case: :mixed)
  defp decode_data_hex(_), do: :error

  defp decode_topic_address(nil), do: nil

  defp decode_topic_address("0x" <> full_hash) when byte_size(full_hash) == 64 do
    "0x" <> binary_part(full_hash, 24, 40)
  end

  defp decode_topic_address(_), do: nil

  defp bytes32_to_hash(bytes) when is_binary(bytes) and byte_size(bytes) == 32 do
    "0x" <> Base.encode16(bytes, case: :lower)
  end

  defp bytes32_to_hash(_), do: nil

  defp decode_dynamic_bytes(bytes, head_offset) do
    with true <- is_integer(head_offset) and head_offset >= 0,
         true <- head_offset + 32 <= byte_size(bytes),
         relative_offset <- decode_word(bytes, head_offset),
         true <- is_integer(relative_offset) and relative_offset >= 0,
         length_offset <- head_offset + relative_offset,
         true <- length_offset + 32 <= byte_size(bytes),
         data_length <- decode_word(bytes, length_offset),
         true <- is_integer(data_length) and data_length >= 0,
         data_offset <- length_offset + 32,
         true <- data_offset + data_length <= byte_size(bytes) do
      binary_part(bytes, data_offset, data_length)
    else
      _ -> nil
    end
  end

  defp decode_word(bytes, offset) do
    bytes
    |> binary_part(offset, 32)
    |> :binary.decode_unsigned()
  end

  defp decode_word_as_hash(bytes, offset) do
    with true <- is_integer(offset) and offset >= 0,
         true <- offset + 32 <= byte_size(bytes) do
      "0x" <> Base.encode16(binary_part(bytes, offset, 32), case: :lower)
    else
      _ -> nil
    end
  end

  defp extend_result(result, _key, value) when is_nil(value), do: result
  defp extend_result(result, key, value), do: Map.put(result, key, value)
end
