defmodule AbsintheCache.PluggableBackendTest do
  @moduledoc """
  Verifies that when a schema uses `use AbsintheCache, provider: SomeProvider`,
  that provider's get_or_store/store are actually used during resolution
  (pluggable backend is exercised).
  """
  use ExUnit.Case, async: false

  defmodule SchemaWithDouble do
    use Absinthe.Schema
    use AbsintheCache, provider: AbsintheCacheTest.TestDoubleProvider
    import AbsintheCache, only: [cache_resolve: 1]

    require Logger

    query do
      field :get_name_cached, non_null(:string) do
        cache_resolve(fn _, _, _ ->
          Logger.info("RESOLVER_RAN")
          {:ok, "CachedValue"}
        end)
      end
    end
  end

  setup do
    # Start our test-double provider with a unique name so we can assert on its calls.
    name = :"test_double_#{System.unique_integer([:positive])}"
    {:ok, _pid} = AbsintheCacheTest.TestDoubleProvider.start_link(name: name)
    Process.put({AbsintheCacheTest.TestDoubleProvider, :name}, name)
    AbsintheCache.clear_all(SchemaWithDouble)
    on_exit(fn -> Process.delete({AbsintheCacheTest.TestDoubleProvider, :name}) end)
    %{provider_name: name}
  end

  test "cached resolution uses the configured provider (get_or_store and store called)", %{
    provider_name: name
  } do
    # First call: miss, resolver runs, provider stores
    {:ok, %{data: %{"getNameCached" => "CachedValue"}}} =
      Absinthe.run("{ getNameCached }", SchemaWithDouble, root_value: %{})

    calls = AbsintheCacheTest.TestDoubleProvider.get_calls(name)
    assert Enum.any?(calls, fn
             {:get_or_store, _cache, _key} -> true
             _ -> false
           end), "Expected at least one get_or_store call on the test double provider, got: #{inspect(calls)}"

    assert Enum.any?(calls, fn
             {:store, _cache, _key} -> true
             _ -> false
           end), "Expected at least one store call after cache miss, got: #{inspect(calls)}"
  end

  test "second identical query hits the provider cache (resolver not run again)" do
    import ExUnit.CaptureLog

    fun = fn ->
      Absinthe.run("{ getNameCached }", SchemaWithDouble, root_value: %{})
    end

    # First run: resolver runs
    assert capture_log(fun) =~ "RESOLVER_RAN"
    # Second run: cache hit, resolver must not run
    refute capture_log(fun) =~ "RESOLVER_RAN"
  end
end
