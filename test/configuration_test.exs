defmodule AbsintheCache.ConfigurationTest do
  use ExUnit.Case, async: false

  alias AbsintheCache.ConCacheProvider, as: Provider

  # Clean up any config we set after each test
  setup do
    on_exit(fn ->
      Application.delete_env(:absinthe_cache, :cache_name)
      Application.delete_env(:absinthe_cache, :cache_provider)
      Application.delete_env(:absinthe_cache, :ttl)
      Application.delete_env(:absinthe_cache, :max_ttl_offset)
    end)
  end

  describe "cache_name configuration" do
    setup do
      {:ok, pid} =
        Provider.start_link(
          name: :custom_cache_name,
          ttl_check_interval: :timer.seconds(30),
          global_ttl: :timer.seconds(300)
        )

      Application.put_env(:absinthe_cache, :cache_name, :custom_cache_name)

      on_exit(fn ->
        ExUnit.CaptureLog.capture_log(fn -> Process.exit(pid, :kill) end)
      end)

      :ok
    end

    test "store/2 and get/1 use the configured cache name" do
      AbsintheCache.store("cfg_key", {:ok, "cfg_value"})
      assert AbsintheCache.get("cfg_key") == {:ok, "cfg_value"}
    end

    test "count/0 uses the configured cache name" do
      assert AbsintheCache.count() == 0
      AbsintheCache.store("cfg_cnt", {:ok, 1})
      assert AbsintheCache.count() == 1
    end

    test "size/0 uses the configured cache name" do
      assert is_float(AbsintheCache.size())
    end

    test "clear_all/0 uses the configured cache name" do
      AbsintheCache.store("cfg_clr", {:ok, 1})
      assert AbsintheCache.count() == 1
      AbsintheCache.clear_all()
      assert AbsintheCache.count() == 0
    end

    test "wrap/3 uses the configured cache name" do
      call_count = :counters.new(1, [:atomics])

      wrapped =
        AbsintheCache.wrap(
          fn ->
            :counters.add(call_count, 1, 1)
            {:ok, "wrapped"}
          end,
          :cfg_wrap_test,
          %{}
        )

      assert wrapped.() == {:ok, "wrapped"}
      assert wrapped.() == {:ok, "wrapped"}
      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "ttl configuration" do
    setup do
      {:ok, pid} =
        Provider.start_link(
          name: :graphql_cache,
          ttl_check_interval: :timer.seconds(30),
          global_ttl: :timer.seconds(300)
        )

      on_exit(fn ->
        ExUnit.CaptureLog.capture_log(fn -> Process.exit(pid, :kill) end)
      end)

      :ok
    end

    test "default TTL is 300-420 when no config is set" do
      {_key, ttl} = AbsintheCache.cache_key(:ttl_default_test, %{})
      assert ttl >= 300
      assert ttl <= 420
    end

    test "custom ttl via Application config changes the base TTL" do
      Application.put_env(:absinthe_cache, :ttl, 600)

      {_key, ttl} = AbsintheCache.cache_key(:ttl_config_test, %{})
      # base 600 + offset 0..120
      assert ttl >= 600
      assert ttl <= 720
    end

    test "custom max_ttl_offset via Application config changes the offset range" do
      Application.put_env(:absinthe_cache, :ttl, 100)
      Application.put_env(:absinthe_cache, :max_ttl_offset, 5)

      {_key, ttl} = AbsintheCache.cache_key(:offset_config_test, %{})
      assert ttl >= 100
      assert ttl <= 105
    end

    test "per-call opts override Application config" do
      Application.put_env(:absinthe_cache, :ttl, 600)

      {_key, ttl} = AbsintheCache.cache_key(:override_test, %{}, ttl: 50, max_ttl_offset: 5)
      assert ttl >= 50
      assert ttl <= 55
    end

    test "caching_params in args override both Application config and per-call opts" do
      Application.put_env(:absinthe_cache, :ttl, 600)

      args = %{caching_params: %{base_ttl: 10, max_ttl_offset: 3}}
      {_key, ttl} = AbsintheCache.cache_key(:params_override_test, args, ttl: 50)
      assert ttl >= 10
      assert ttl <= 13
    end
  end

  describe "cache_provider configuration" do
    test "uses ConCacheProvider by default" do
      spec = AbsintheCache.child_spec(name: :provider_test, id: :provider_test)
      assert is_map(spec)
      assert spec.id == :provider_test
    end

    test "custom provider module is used when configured" do
      defmodule TestProvider do
        @behaviour AbsintheCache.Behaviour

        def start_link(_opts), do: {:ok, self()}
        def child_spec(opts), do: %{id: :test_provider, start: {__MODULE__, :start_link, [opts]}}
        def get(_cache, _key), do: {:ok, "from_test_provider"}
        def store(_cache, _key, _value), do: :ok
        def get_or_store(_cache, _key, _func, _middleware), do: {:ok, "from_test_provider"}
        def size(_cache), do: 0.0
        def count(_cache), do: 42
        def clear_all(_cache), do: :ok
      end

      Application.put_env(:absinthe_cache, :cache_provider, TestProvider)

      assert AbsintheCache.count() == 42
      assert AbsintheCache.size() == 0.0
      assert AbsintheCache.get("any") == {:ok, "from_test_provider"}
    end
  end
end
