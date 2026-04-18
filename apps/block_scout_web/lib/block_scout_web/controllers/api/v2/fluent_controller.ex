defmodule BlockScoutWeb.API.V2.FluentController do
  use BlockScoutWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import BlockScoutWeb.Chain,
    only: [
      next_page_params: 3,
      paging_options: 1,
      split_list_by_page: 1
    ]

  import BlockScoutWeb.PagingHelper, only: [delete_parameters_from_next_page_params: 1]

  alias BlockScoutWeb.API.V2.{AddressView, FluentView}
  alias BlockScoutWeb.AccessHelper
  alias Explorer.Chain
  alias Explorer.Chain.Fluent.Reader
  alias Explorer.Chain.Hash

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  plug(OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true)

  @api_true [api?: true]

  @runtime_upgrades_address "0x0000000000000000000000000000000000520010"
  @runtime_upgrades_address_hash (case Hash.Address.cast(@runtime_upgrades_address) do
                                    {:ok, address_hash} -> address_hash
                                    _ -> nil
                                  end)

  @bridge_operations_address "0x9CAcf613fC29015893728563f423fD26dCdB8Ddc"
  @bridge_operations_address_hash (case Hash.Address.cast(@bridge_operations_address) do
                                     {:ok, address_hash} -> address_hash
                                     _ -> nil
                                   end)

  operation :runtime_upgrades,
    summary: "List runtime-upgrade aggregates grouped by genesis hash",
    description:
      "Returns runtime-upgrade aggregates grouped by genesis hash for events emitted by the runtime-upgrade system contract.",
    parameters: base_params(),
    responses: [
      ok:
        {"Runtime-upgrade aggregate list.", "application/json",
         %Schema{
           type: :object,
           properties: %{
             items: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 properties: %{
                   genesis_hash: Schemas.General.FullHash,
                   genesis_version: %Schema{type: :integer, nullable: true},
                   upgrades_count: %Schema{type: :integer, nullable: false}
                 },
                 nullable: false,
                 additionalProperties: false
               }
             }
           },
           nullable: false,
           additionalProperties: false
         }}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/runtime-upgrades` endpoint.

  Returns runtime-upgrade aggregates grouped by `genesis_hash` (EVM `topic2`, stored
  as `third_topic` in Blockscout logs schema) for the runtime-upgrade system contract.
  """
  @spec runtime_upgrades(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def runtime_upgrades(conn, _params) do
    runtime_upgrades =
      case @runtime_upgrades_address_hash do
        nil -> []
        address_hash -> Chain.address_to_runtime_upgrades(address_hash, @api_true)
      end

    conn
    |> put_status(200)
    |> put_view(AddressView)
    |> render(:runtime_upgrades, %{runtime_upgrades: runtime_upgrades})
  end

  operation :runtime_upgrades_by_genesis_hash,
    summary: "List runtime-upgrade events by genesis hash",
    description:
      "Returns paginated runtime-upgrade events for the given genesis hash from the runtime-upgrade system contract.",
    parameters:
      [
        %OpenApiSpex.Parameter{
          name: :genesis_hash,
          in: :path,
          schema: %Schema{type: :string},
          required: true,
          description: "Genesis hash in the path. Accepts 0x-prefixed full hash, bare 64-hex hash, optional quotes, and 0X prefix."
        }
      ] ++
        base_params() ++ define_paging_params(["block_number", "index", "items_count"]),
    responses: [
      ok:
        {"Runtime-upgrade events for the given genesis hash.", "application/json",
         paginated_response(
           items: %Schema{
             type: :object,
             properties: %{
               transaction_hash: Schemas.General.FullHash,
               block_number: %Schema{type: :integer, nullable: true},
               log_index: %Schema{type: :integer, nullable: true},
               block_timestamp: Schemas.General.TimestampNullable,
               target_address_hash: Schemas.General.AddressHash,
               genesis_hash: Schemas.General.FullHash,
               genesis_version: %Schema{type: :integer, nullable: true},
               code_hash: Schemas.General.FullHashNullable
             },
             nullable: false,
             additionalProperties: false
           },
           next_page_params_example: %{"block_number" => 22_546_398, "index" => 268, "items_count" => 50}
         )},
      unprocessable_entity: JsonErrorResponse.response(),
      forbidden: ForbiddenResponse.response()
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/runtime-upgrades/:genesis_hash` endpoint.

  Returns a paginated list of runtime-upgrade events for the given `genesis_hash`.
  """
  @spec runtime_upgrades_by_genesis_hash(Plug.Conn.t(), map()) :: {:format, :error} | Plug.Conn.t()
  def runtime_upgrades_by_genesis_hash(conn, %{genesis_hash: genesis_hash_param} = params) do
    with {:ok, genesis_hash} <- validate_optional_topic(genesis_hash_param) do
      {logs, next_page_params} =
        case @runtime_upgrades_address_hash do
          nil ->
            {[], nil}

          address_hash ->
            options =
              params
              |> paging_options()
              |> Keyword.merge(@api_true)

            results_plus_one = Chain.runtime_upgrades_by_genesis_hash(address_hash, genesis_hash, options)
            {logs, next_page} = split_list_by_page(results_plus_one)

            next_page_params =
              next_page
              |> next_page_params(logs, delete_parameters_from_next_page_params(params))

            {logs, next_page_params}
        end

      conn
      |> put_status(200)
      |> put_view(AddressView)
      |> render(:runtime_upgrade_logs, %{logs: logs, next_page_params: next_page_params})
    end
  end

  operation :bridge_operations,
    summary: "List decoded bridge events",
    description:
      "Returns paginated decoded bridge events for Fluent bridge operations. Uses the default Fluent bridge contract address when `bridge_address` is not provided.",
    parameters:
      base_params() ++
        define_paging_params(["block_number", "index", "items_count"]) ++
        [
          %OpenApiSpex.Parameter{
            name: :operation,
            in: :query,
            schema: %Schema{type: :string, enum: ["deposit", "withdraw"]},
            required: false,
            description:
              "Optional operation filter. `deposit` returns `SentMessage`; `withdraw` returns `ReceivedMessage`, `RollbackMessage`, `RetriedFailedMessage`, and `ReceivedMessageRollback`."
          },
          %OpenApiSpex.Parameter{
            name: :bridge_address,
            in: :query,
            schema: Schemas.General.AddressHash,
            required: false,
            description:
              "Optional bridge contract address override. If omitted, the default Fluent bridge address is used."
          }
        ],
    responses: [
      ok:
        {"Bridge operation logs.", "application/json",
         paginated_response(
           items: %Schema{
             type: :object,
             properties: %{
               transaction_hash: Schemas.General.FullHash,
               block_number: %Schema{type: :integer, nullable: true},
               log_index: %Schema{type: :integer, nullable: true},
               block_timestamp: Schemas.General.TimestampNullable,
               bridge_address: Schemas.General.AddressHashNullable,
               event: %Schema{
                 type: :string,
                 enum: ["sent_message", "received_message", "rollback_message", "retried_failed_message", "received_message_rollback"],
                 nullable: true
               },
               operation: %Schema{type: :string, enum: ["deposit", "withdraw"], nullable: true},
               sender_address_hash: Schemas.General.AddressHashNullable,
               target_address_hash: Schemas.General.AddressHashNullable,
               value: %Schema{type: :integer, nullable: true},
               fee: %Schema{type: :integer, nullable: true},
               chain_id: %Schema{type: :integer, nullable: true},
               valid_until_block_number: %Schema{type: :integer, nullable: true},
               source_block_number: %Schema{type: :integer, nullable: true},
               nonce: %Schema{type: :integer, nullable: true},
               message_hash: Schemas.General.FullHashNullable,
               successful_call: %Schema{type: :boolean, nullable: true},
               rollback_block_number: %Schema{type: :integer, nullable: true},
               message_data: Schemas.General.HexStringNullable,
               return_data: Schemas.General.HexStringNullable
             },
             nullable: false,
             additionalProperties: false
           },
           next_page_params_example: %{"block_number" => 22_546_398, "index" => 268, "items_count" => 50}
         )},
      unprocessable_entity: JsonErrorResponse.response(),
      forbidden: ForbiddenResponse.response()
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/bridge-operations` endpoint.

  Returns paginated decoded bridge events for the default Fluent bridge contract,
  or for `bridge_address` query param if provided.
  """
  @spec bridge_operations(Plug.Conn.t(), map()) :: {:format, :error} | {:restricted_access, true} | Plug.Conn.t()
  def bridge_operations(conn, params) do
    with {:ok, operation} <- validate_bridge_operation(params["operation"] || params[:operation]),
         {:ok, bridge_address_hash} <-
           validate_optional_bridge_address(params["bridge_address"] || params[:bridge_address], params) do
      address_hash = bridge_address_hash || @bridge_operations_address_hash

      {logs, next_page_params} =
        case address_hash do
          nil ->
            {[], nil}

          address_hash ->
            options =
              params
              |> paging_options()
              |> Keyword.merge(@api_true)

            results_plus_one = Chain.bridge_operations(address_hash, operation, options)
            {logs, next_page} = split_list_by_page(results_plus_one)

            next_page_params =
              next_page
              |> next_page_params(logs, delete_parameters_from_next_page_params(params))

            {logs, next_page_params}
        end

      conn
      |> put_status(200)
      |> put_view(AddressView)
      |> render(:bridge_operation_logs, %{logs: logs, next_page_params: next_page_params})
    end
  end

  operation :batch,
    summary: "Get Fluent batch by number",
    description: "Returns details for a specific indexed Fluent batch.",
    parameters:
      [
        %OpenApiSpex.Parameter{
          name: :number,
          in: :path,
          schema: %Schema{type: :integer},
          required: true,
          description: "Batch number."
        }
      ] ++ base_params(),
    responses: [
      ok: {"Fluent batch details.", "application/json", %Schema{type: :object, additionalProperties: true}},
      not_found: BlockScoutWeb.Schemas.API.V2.ErrorResponses.NotFoundResponse.response(),
      unprocessable_entity: JsonErrorResponse.response()
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/batches/:number` endpoint.
  """
  @spec batch(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, :not_found}
  def batch(conn, %{number: number}) do
    number = if is_binary(number), do: String.to_integer(number), else: number

    options =
      [necessity_by_association: %{bundle: :optional}]
      |> Keyword.merge(@api_true)

    case Reader.batch(number, options) do
      {:ok, batch} ->
        conn
        |> put_status(200)
        |> put_view(FluentView)
        |> render(:fluent_batch, %{batch: batch})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  operation :batches,
    summary: "List indexed Fluent batches",
    description: "Returns paginated indexed Fluent transaction batches.",
    parameters: base_params() ++ define_paging_params(["number", "items_count"]),
    responses: [
      ok:
        {"Fluent batches list.", "application/json",
         paginated_response(
           items: %Schema{type: :object, nullable: false, additionalProperties: true},
           next_page_params_example: %{"number" => 128, "items_count" => 50}
         )}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/batches` endpoint.
  """
  @spec batches(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def batches(conn, params) do
    {batches, next_page} =
      params
      |> paging_options()
      |> Keyword.merge(@api_true)
      |> Reader.batches()
      |> split_list_by_page()

    next_page_params =
      next_page
      |> next_page_params(batches, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> put_view(FluentView)
    |> render(:fluent_batches, %{batches: batches, next_page_params: next_page_params})
  end

  operation :batches_count,
    summary: "Count indexed Fluent batches",
    description: "Returns total count of indexed Fluent batches.",
    parameters: base_params(),
    responses: [
      ok: {"Fluent batches count.", "application/json", %Schema{type: :integer, nullable: false}}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/batches/count` endpoint.
  """
  @spec batches_count(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def batches_count(conn, _params) do
    conn
    |> put_status(200)
    |> put_view(FluentView)
    |> render(:fluent_batches_count, %{count: batch_latest_number() + 1})
  end

  operation :deposits,
    summary: "List indexed Fluent deposits",
    description: "Returns paginated deposit operations indexed from Fluent bridge events on L1 and L2.",
    parameters: base_params() ++ define_paging_params(["id", "items_count"]),
    responses: [
      ok:
        {"Fluent deposits list.", "application/json",
         paginated_response(
           items: %Schema{type: :object, nullable: false, additionalProperties: true},
           next_page_params_example: %{"id" => 128, "items_count" => 50}
         )}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/deposits` endpoint.
  """
  @spec deposits(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deposits(conn, params) do
    {deposits, next_page} =
      params
      |> paging_options()
      |> Keyword.merge(@api_true)
      |> Reader.deposits()
      |> split_list_by_page()

    next_page_params =
      next_page
      |> next_page_params(deposits, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> put_view(FluentView)
    |> render(:fluent_bridge_items, %{items: deposits, next_page_params: next_page_params, type: :deposits})
  end

  operation :deposits_count,
    summary: "Count indexed Fluent deposits",
    description: "Returns total count of indexed Fluent deposits.",
    parameters: base_params(),
    responses: [
      ok: {"Fluent deposits count.", "application/json", %Schema{type: :integer, nullable: false}}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/deposits/count` endpoint.
  """
  @spec deposits_count(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deposits_count(conn, _params) do
    count = Reader.deposits_count(@api_true)

    conn
    |> put_status(200)
    |> put_view(FluentView)
    |> render(:fluent_bridge_items_count, %{count: count})
  end

  operation :withdrawals,
    summary: "List indexed Fluent withdrawals",
    description: "Returns paginated withdrawal operations indexed from Fluent bridge events on L1 and L2.",
    parameters: base_params() ++ define_paging_params(["id", "items_count"]),
    responses: [
      ok:
        {"Fluent withdrawals list.", "application/json",
         paginated_response(
           items: %Schema{type: :object, nullable: false, additionalProperties: true},
           next_page_params_example: %{"id" => 128, "items_count" => 50}
         )}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/withdrawals` endpoint.
  """
  @spec withdrawals(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def withdrawals(conn, params) do
    {withdrawals, next_page} =
      params
      |> paging_options()
      |> Keyword.merge(@api_true)
      |> Reader.withdrawals()
      |> split_list_by_page()

    next_page_params =
      next_page
      |> next_page_params(withdrawals, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> put_view(FluentView)
    |> render(:fluent_bridge_items, %{items: withdrawals, next_page_params: next_page_params, type: :withdrawals})
  end

  operation :withdrawals_count,
    summary: "Count indexed Fluent withdrawals",
    description: "Returns total count of indexed Fluent withdrawals.",
    parameters: base_params(),
    responses: [
      ok: {"Fluent withdrawals count.", "application/json", %Schema{type: :integer, nullable: false}}
    ]

  @doc """
  Handles GET requests to `/api/v2/fluent/withdrawals/count` endpoint.
  """
  @spec withdrawals_count(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def withdrawals_count(conn, _params) do
    count = Reader.withdrawals_count(@api_true)

    conn
    |> put_status(200)
    |> put_view(FluentView)
    |> render(:fluent_bridge_items_count, %{count: count})
  end

  defp batch_latest_number do
    case Reader.batch(:latest, @api_true) do
      {:ok, batch} -> batch.number
      {:error, :not_found} -> -1
    end
  end

  @spec validate_address_hash(String.t(), any()) ::
          {:format, :error}
          | {:restricted_access, true}
          | {:ok, Hash.t()}
  defp validate_address_hash(address_hash_string, params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params) do
      {:ok, address_hash}
    end
  end

  @spec validate_optional_address_hash(nil | String.t(), any()) ::
          {:format, :error}
          | {:restricted_access, true}
          | {:ok, nil | Hash.t()}
  defp validate_optional_address_hash(address_hash_string, params) do
    case address_hash_string do
      nil ->
        {:ok, nil}

      _ ->
        validate_address_hash(address_hash_string, params)
    end
  end

  @spec validate_optional_topic(nil | String.t() | Hash.Full.t()) :: {:ok, nil | Hash.Full.t()} | {:format, :error}
  defp validate_optional_topic(topic) do
    topic =
      if is_binary(topic) do
        topic
        |> String.trim()
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.trim_leading("'")
        |> String.trim_trailing("'")
        |> normalize_full_hash_input()
      else
        topic
      end

    case topic do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      "null" ->
        {:ok, nil}

      %Hash{byte_count: 32} = topic_hash ->
        {:ok, topic_hash}

      _ ->
        with {:format, {:ok, topic}} <- {:format, Chain.string_to_full_hash(topic)} do
          {:ok, topic}
        end
    end
  end

  defp normalize_full_hash_input(<<"0X", rest::binary>>), do: "0x" <> rest

  defp normalize_full_hash_input(topic) when is_binary(topic) do
    if String.match?(topic, ~r/^[A-Fa-f0-9]{64}$/) do
      "0x" <> topic
    else
      topic
    end
  end

  @spec validate_optional_bridge_address(nil | String.t() | Hash.Address.t(), any()) ::
          {:format, :error}
          | {:restricted_access, true}
          | {:ok, nil | Hash.Address.t()}
  defp validate_optional_bridge_address(address_hash, params)

  defp validate_optional_bridge_address(nil, _params), do: {:ok, nil}

  defp validate_optional_bridge_address(%Hash{byte_count: 20} = address_hash, _params), do: {:ok, address_hash}

  defp validate_optional_bridge_address(address_hash, params) when is_binary(address_hash) do
    address_hash =
      address_hash
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> String.trim_leading("'")
      |> String.trim_trailing("'")

    case address_hash do
      "" -> {:ok, nil}
      "null" -> {:ok, nil}
      _ -> validate_optional_address_hash(address_hash, params)
    end
  end

  defp validate_optional_bridge_address(_, _), do: {:format, :error}

  @spec validate_bridge_operation(nil | String.t() | atom()) :: {:ok, :all | :deposit | :withdraw} | {:format, :error}
  defp validate_bridge_operation(operation)

  defp validate_bridge_operation(nil), do: {:ok, :all}
  defp validate_bridge_operation(""), do: {:ok, :all}
  defp validate_bridge_operation(:all), do: {:ok, :all}
  defp validate_bridge_operation(:deposit), do: {:ok, :deposit}
  defp validate_bridge_operation(:withdraw), do: {:ok, :withdraw}

  defp validate_bridge_operation(operation) when is_binary(operation) do
    case String.downcase(String.trim(operation)) do
      "" -> {:ok, :all}
      "deposit" -> {:ok, :deposit}
      "withdraw" -> {:ok, :withdraw}
      _ -> {:format, :error}
    end
  end

  defp validate_bridge_operation(_), do: {:format, :error}
end
