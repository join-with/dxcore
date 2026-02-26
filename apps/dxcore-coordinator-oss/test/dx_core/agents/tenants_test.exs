defmodule DxCore.Agents.TenantsTest do
  use ExUnit.Case, async: false

  alias DxCore.Agents.Tenants
  alias DxCore.Agents.Tenants.Tenant
  alias DxCore.Agents.Scope

  setup do
    # Clear the ETS table before each test
    :ets.delete_all_objects(:dxcore_agents_tenants)
    :ok
  end

  describe "verify_token/1" do
    test "returns {:ok, %Scope{}} for valid token" do
      {:ok, raw_token} = Tenants.create_tenant("acme", "Acme Corp")

      assert {:ok, %Scope{tenant_id: "acme", tenant_name: "Acme Corp"}} =
               Tenants.verify_token(raw_token)
    end

    test "returns :error for invalid token" do
      assert :error = Tenants.verify_token("tdx_bogus_token")
    end
  end

  describe "create_tenant/2" do
    test "generates tdx_ prefixed token" do
      {:ok, raw_token} = Tenants.create_tenant("acme", "Acme Corp")
      assert String.starts_with?(raw_token, "tdx_")
    end

    test "created token can be verified" do
      {:ok, raw_token} = Tenants.create_tenant("test-co", "Test Company")

      assert {:ok, %Scope{tenant_id: "test-co", tenant_name: "Test Company"}} =
               Tenants.verify_token(raw_token)
    end
  end

  describe "list_tenants/0" do
    test "returns tenants without token hashes" do
      Tenants.create_tenant("acme", "Acme Corp")
      Tenants.create_tenant("globex", "Globex Inc")

      tenants = Tenants.list_tenants()
      assert length(tenants) == 2

      ids = Enum.map(tenants, & &1.id) |> Enum.sort()
      assert ids == ["acme", "globex"]

      Enum.each(tenants, fn %Tenant{token_hash: hash} ->
        assert hash == nil
      end)
    end
  end

  describe "seed_from_env/0" do
    test "populates from env var" do
      System.put_env("DXCORE_AGENTS_TOKENS", "tenant1:secret1,tenant2:secret2")

      Tenants.seed_from_env()

      assert {:ok, %Scope{tenant_id: "tenant1", tenant_name: "tenant1"}} =
               Tenants.verify_token("secret1")

      assert {:ok, %Scope{tenant_id: "tenant2", tenant_name: "tenant2"}} =
               Tenants.verify_token("secret2")

      System.delete_env("DXCORE_AGENTS_TOKENS")
    end
  end
end
