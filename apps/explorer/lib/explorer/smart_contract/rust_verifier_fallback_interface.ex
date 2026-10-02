defmodule Explorer.SmartContract.RustVerifierFallbackInterface do
  @moduledoc """
  Adapter for a self-hosted https://github.com/blockscout/blockscout-rs/blob/main/smart-contract-verifier
  that takes over Solidity and Vyper verifications when the primary verifier
  (`Explorer.SmartContract.RustVerifierInterface`) does not know the requested compiler version.

  Configured by `MICROSERVICE_SC_VERIFIER_FALLBACK_URL`; disabled when that variable is unset.
  Requests to it carry no API key. Routing lives in `Explorer.SmartContract.RustVerifierFallback`.
  """
  use Explorer.SmartContract.RustVerifierInterfaceBehaviour, config_key: __MODULE__
end
