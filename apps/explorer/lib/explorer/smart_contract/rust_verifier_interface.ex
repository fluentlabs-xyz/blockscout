defmodule Explorer.SmartContract.RustVerifierInterface do
  @moduledoc """
    Adapter for contracts verification with https://github.com/blockscout/blockscout-rs/blob/main/smart-contract-verifier

    Verifications for compiler versions this verifier does not list fall back to
    `Explorer.SmartContract.RustVerifierFallbackInterface` when `MICROSERVICE_SC_VERIFIER_FALLBACK_URL` is set.
  """
  use Explorer.SmartContract.RustVerifierInterfaceBehaviour, fallback: true
end
