defmodule AbsintheCacheTest do
  defmodule Schema do
    use Absinthe.Schema
    import AbsintheCache, only: [cache_resolve: 1, cache_resolve: 2]

    require Logger

    query do
      field :cached_ok, non_null(:string) do
        cache_resolve(fn _, _, _ ->
          Logger.info("CACHED_OK_CALLED")
          {:ok, "cached_value"}
        end)
      end

      field :not_cached, non_null(:string) do
        resolve(fn _, _, _ ->
          Logger.info("NOT_CACHED_CALLED")
          {:ok, "uncached_value"}
        end)
      end

      field :cached_error, :string do
        cache_resolve(fn _, _, _ ->
          Logger.info("CACHED_ERROR_CALLED")
          {:error, "something went wrong"}
        end)
      end

      field :cached_nocache, :string do
        cache_resolve(fn _, _, _ ->
          Logger.info("CACHED_NOCACHE_CALLED")
          {:nocache, {:ok, "temporary"}}
        end)
      end

      field :cached_honor_flag, non_null(:string) do
        cache_resolve(
          fn _, _, _ ->
            Logger.info("CACHED_HONOR_FLAG_CALLED")
            {:ok, "honor_value"}
          end,
          honor_do_not_cache_flag: true
        )
      end

      field :cached_fun_name, non_null(:string) do
        cache_resolve(
          fn _, _, _ ->
            Logger.info("CACHED_FUN_NAME_CALLED")
            {:ok, "named_value"}
          end,
          fun_name: :custom_name
        )
      end
    end
  end

  use AbsintheCache.TestCase, async: false

  import ExUnit.CaptureLog

  describe "cache_resolve macro" do
    test "cached resolver executes only on first call" do
      fun = fn -> Absinthe.run("{ cachedOk }", Schema, root_value: %{}) end

      assert capture_log(fun) =~ "CACHED_OK_CALLED"
      refute capture_log(fun) =~ "CACHED_OK_CALLED"
      refute capture_log(fun) =~ "CACHED_OK_CALLED"
    end

    test "uncached resolver executes every time" do
      fun = fn -> Absinthe.run("{ notCached }", Schema, root_value: %{}) end

      assert capture_log(fun) =~ "NOT_CACHED_CALLED"
      assert capture_log(fun) =~ "NOT_CACHED_CALLED"
      assert capture_log(fun) =~ "NOT_CACHED_CALLED"
    end

    test "error result is not cached — resolver re-executes each time" do
      fun = fn -> Absinthe.run("{ cachedError }", Schema, root_value: %{}) end

      assert capture_log(fun) =~ "CACHED_ERROR_CALLED"
      assert capture_log(fun) =~ "CACHED_ERROR_CALLED"
      assert capture_log(fun) =~ "CACHED_ERROR_CALLED"
    end

    test "nocache result is not cached — resolver re-executes each time" do
      fun = fn -> Absinthe.run("{ cachedNocache }", Schema, root_value: %{}) end

      assert capture_log(fun) =~ "CACHED_NOCACHE_CALLED"
      assert capture_log(fun) =~ "CACHED_NOCACHE_CALLED"
      assert capture_log(fun) =~ "CACHED_NOCACHE_CALLED"
    end

    test "honor_do_not_cache_flag: true skips cache when process flag is set" do
      fun = fn ->
        Process.put(:do_not_cache_query, true)
        Absinthe.run("{ cachedHonorFlag }", Schema, root_value: %{})
      end

      assert capture_log(fun) =~ "CACHED_HONOR_FLAG_CALLED"
      assert capture_log(fun) =~ "CACHED_HONOR_FLAG_CALLED"
      assert capture_log(fun) =~ "CACHED_HONOR_FLAG_CALLED"
    end

    test "honor_do_not_cache_flag: true still caches when flag is NOT set" do
      Process.delete(:do_not_cache_query)

      fun = fn ->
        Absinthe.run("{ cachedHonorFlag }", Schema, root_value: %{})
      end

      assert capture_log(fun) =~ "CACHED_HONOR_FLAG_CALLED"
      refute capture_log(fun) =~ "CACHED_HONOR_FLAG_CALLED"
    end

    test "fun_name option works — resolver is cached using the custom name" do
      fun = fn -> Absinthe.run("{ cachedFunName }", Schema, root_value: %{}) end

      assert capture_log(fun) =~ "CACHED_FUN_NAME_CALLED"
      refute capture_log(fun) =~ "CACHED_FUN_NAME_CALLED"
    end
  end

  describe "wrap/2,3,4" do
    test "wrapped function caches result, second call returns cached" do
      call_count = :counters.new(1, [:atomics])

      wrapped = AbsintheCache.wrap(
        fn ->
          :counters.add(call_count, 1, 1)
          {:ok, "wrapped_val"}
        end,
        :wrap_test,
        %{}
      )

      assert wrapped.() == {:ok, "wrapped_val"}
      assert wrapped.() == {:ok, "wrapped_val"}
      assert :counters.get(call_count, 1) == 1
    end

    test "wrapped function with different args produces separate cache entries" do
      fun1 = AbsintheCache.wrap(fn -> {:ok, "a"} end, :wrap_args, %{x: 1})
      fun2 = AbsintheCache.wrap(fn -> {:ok, "b"} end, :wrap_args, %{x: 2})

      assert fun1.() == {:ok, "a"}
      assert fun2.() == {:ok, "b"}
    end

    test "wrapped function returning error is not cached" do
      call_count = :counters.new(1, [:atomics])

      wrapped = AbsintheCache.wrap(
        fn ->
          :counters.add(call_count, 1, 1)
          {:error, "fail"}
        end,
        :wrap_error,
        %{}
      )

      assert wrapped.() == {:error, "fail"}
      assert wrapped.() == {:error, "fail"}
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "store/get" do
    test "direct store + get round-trip" do
      AbsintheCache.store(:graphql_cache, "direct_key", {:ok, "direct_val"})
      assert AbsintheCache.get("direct_key") == {:ok, "direct_val"}
    end

    test "get returns nil for missing key" do
      assert AbsintheCache.get("missing_key") == nil
    end

    test "store with {key, ttl} tuple" do
      AbsintheCache.store(:graphql_cache, {"ttl_key", 60}, {:ok, "ttl_val"})
      assert AbsintheCache.get({"ttl_key", 60}) == {:ok, "ttl_val"}
    end
  end

  describe "count, size, clear_all" do
    test "count returns 0 on empty cache" do
      assert AbsintheCache.count() == 0
    end

    test "count increments after stores" do
      AbsintheCache.store(:graphql_cache, "cnt1", {:ok, 1})
      AbsintheCache.store(:graphql_cache, "cnt2", {:ok, 2})
      assert AbsintheCache.count() == 2
    end

    test "size returns a non-negative float" do
      size = AbsintheCache.size()
      assert is_float(size)
      assert size >= 0.0
    end

    test "clear_all resets count to 0" do
      AbsintheCache.store(:graphql_cache, "clr1", {:ok, 1})
      AbsintheCache.store(:graphql_cache, "clr2", {:ok, 2})
      assert AbsintheCache.count() > 0

      AbsintheCache.clear_all()
      assert AbsintheCache.count() == 0
    end
  end

  describe "child_spec" do
    test "returns a valid child spec map with :id and :start" do
      spec = AbsintheCache.child_spec(name: :test_spec_cache, id: :test_spec_cache)
      assert is_map(spec)
      assert Map.has_key?(spec, :id)
      assert Map.has_key?(spec, :start)
    end
  end
end
