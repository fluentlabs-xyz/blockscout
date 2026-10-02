defmodule Explorer.SmartContract.RustVerifierFallback do
  @moduledoc """
  Routes Solidity and Vyper verifications between the primary Rust verifier and the fallback one
  by compiler version, and merges their compiler version lists.

  The primary verifier is normally the public eth-bytecode-db, whose compiler list lags new solc
  releases. A verification whose compiler version the primary does not list goes to the fallback
  `smart-contract-verifier`; every other verification keeps going to the primary, so it still lands
  in the shared eth-bytecode-db database. When the fallback is disabled, or the primary version
  list cannot be fetched, requests go to the primary unchanged.
  """

  alias Explorer.SmartContract.RustVerifierFallbackInterface
  alias Explorer.Utility.Microservice

  require Logger

  @type compiler :: :solc | :vyper
  @type versions_result :: {:ok, [String.t()]} | {:error, any()}

  @doc """
  Whether a fallback verifier is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Microservice.check_enabled(RustVerifierFallbackInterface) == :ok

  @doc """
  Picks the interface module a verification request is posted to.

  `primary` is the module that received the request. It is returned unless the fallback is
  enabled, the primary's version list is available, and the request's `compilerVersion` is
  missing from that list.
  """
  @spec verifier_for(module(), compiler(), map()) :: module()
  def verifier_for(primary, compiler, %{"compilerVersion" => compiler_version}) do
    with true <- enabled?(),
         {:ok, versions} when is_list(versions) <- versions_list(primary, compiler),
         false <- compiler_version in versions do
      Logger.info(fn ->
        "Compiler version #{compiler_version} is missing from the primary verifier, verifying through the fallback verifier"
      end)

      RustVerifierFallbackInterface
    else
      _ -> primary
    end
  end

  def verifier_for(primary, _compiler, _body), do: primary

  @doc """
  Adds the fallback verifier's compiler versions to the primary's list.

  A primary error is returned as is; a fallback error leaves the primary list unchanged.
  """
  @spec add_fallback_versions(versions_result(), compiler()) :: versions_result()
  def add_fallback_versions({:ok, primary_versions} = primary_result, compiler) when is_list(primary_versions) do
    with true <- enabled?(),
         {:ok, fallback_versions} when is_list(fallback_versions) <-
           versions_list(RustVerifierFallbackInterface, compiler) do
      {:ok, merge_versions(primary_versions, fallback_versions)}
    else
      {:error, reason} ->
        Logger.warning(fn -> "Could not fetch #{compiler} versions from the fallback verifier: #{inspect(reason)}" end)
        primary_result

      _ ->
        primary_result
    end
  end

  def add_fallback_versions(result, _compiler), do: result

  @doc """
  Unites two compiler version lists without duplicates, newest version first.

  Versions look like `v0.8.37+commit.f401782d`, `v0.8.37-pre.1+commit.…` or
  `v0.8.36-nightly.2026.1.5+commit.…`; they are ordered as semantic versions. Entries that do not
  parse keep their relative order and go last.
  """
  @spec merge_versions([String.t()], [String.t()]) :: [String.t()]
  def merge_versions(primary_versions, fallback_versions) do
    (primary_versions ++ fallback_versions)
    |> Enum.uniq()
    |> Enum.sort(&newer_or_equal?/2)
  end

  defp newer_or_equal?(left, right) do
    case {parse_version(left), parse_version(right)} do
      {{:ok, left_version}, {:ok, right_version}} -> Version.compare(left_version, right_version) != :lt
      {{:ok, _}, :error} -> true
      {:error, {:ok, _}} -> false
      {:error, :error} -> true
    end
  end

  defp parse_version("v" <> version), do: Version.parse(version)
  defp parse_version(version), do: Version.parse(version)

  defp versions_list(interface, :solc), do: interface.get_versions_list()
  defp versions_list(interface, :vyper), do: interface.vyper_get_versions_list()
end
