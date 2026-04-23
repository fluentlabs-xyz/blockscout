defmodule Explorer.Chain.SmartContract.Proxy.EIP7702Test do
  use Explorer.DataCase

  alias Explorer.Chain.SmartContract.Proxy.EIP7702

  @delegate_hex "0102030405060708090a0b0c0d0e0f1011121314"
  @delegate_address "0x" <> @delegate_hex

  describe "get_delegate_address/1" do
    test "extracts delegate from canonical EIP-7702 bytecode" do
      contract_code_bytes = Base.decode16!("EF0100" <> @delegate_hex, case: :mixed)

      assert EIP7702.get_delegate_address(contract_code_bytes) == @delegate_address
    end

    test "extracts delegate from Fluent ownable bytecode with metadata" do
      contract_code_bytes = Base.decode16!("EF4400" <> @delegate_hex <> "DEADBEEF", case: :mixed)

      assert EIP7702.get_delegate_address(contract_code_bytes) == @delegate_address
    end

    test "returns nil for non-EIP-7702-like bytecode" do
      assert EIP7702.get_delegate_address(<<1, 2, 3>>) == nil
    end
  end

  describe "get_implementation_address_hash_strings/2" do
    test "returns delegate for Fluent ownable account" do
      proxy_address = insert(:address, contract_code: "0xEF4400" <> @delegate_hex <> "DEADBEEF")

      assert EIP7702.get_implementation_address_hash_strings(proxy_address.hash) == [@delegate_address]
    end
  end
end
