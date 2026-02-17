defmodule AbsintheCache.ConCacheProviderTest do
  use ExUnit.Case, async: true

  alias AbsintheCache.ConCacheProvider, as: Provider

  @cache_name :test_provider_cache

  setup do
    {:ok, pid} =
      Provider.start_link(
        name: @cache_name,
        ttl_check_interval: :timer.seconds(30),
        global_ttl: :timer.seconds(300)
      )

    on_exit(fn ->
      ExUnit.CaptureLog.capture_log(fn -> Process.exit(pid, :kill) end)
    end)

    %{cache_pid: pid}
  end

  describe "get/2" do
    test "returns nil for missing key" do
      assert Provider.get(@cache_name, "nonexistent") == nil
    end
  end

  describe "store/3" do
    test "stores {:ok, value} and retrieves it with get/2" do
      Provider.store(@cache_name, "key1", {:ok, "hello"})
      assert Provider.get(@cache_name, "key1") == {:ok, "hello"}
    end

    test "ignores {:error, reason} — value is not persisted" do
      Provider.store(@cache_name, "err_key", {:error, "bad"})
      assert Provider.get(@cache_name, "err_key") == nil
    end

    test "ignores {:nocache, value} — value is not persisted" do
      Provider.store(@cache_name, "nc_key", {:nocache, {:ok, "temp"}})
      assert Provider.get(@cache_name, "nc_key") == nil
    end
  end

  defp identity_middleware(_cache, _key, result), do: result

  describe "get_or_store/4" do

    test "executes function on cache miss" do
      result =
        Provider.get_or_store(@cache_name, "miss_key", fn -> {:ok, "computed"} end, &identity_middleware/3)

      assert result == {:ok, "computed"}
    end

    test "returns cached value on hit without re-executing" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, "value"}
      end

      Provider.get_or_store(@cache_name, "hit_key", fun, &identity_middleware/3)
      Provider.get_or_store(@cache_name, "hit_key", fun, &identity_middleware/3)
      Provider.get_or_store(@cache_name, "hit_key", fun, &identity_middleware/3)

      assert :counters.get(call_count, 1) == 1
    end

    test "with {:nocache, {:ok, value}} returns value, doesn't cache, sets :__do_not_cache_query__" do
      Process.delete(:__do_not_cache_query__)

      result =
        Provider.get_or_store(
          @cache_name,
          "nocache_key",
          fn -> {:nocache, {:ok, "temp_val"}} end,
          &identity_middleware/3
        )

      assert result == {:ok, "temp_val"}
      assert Process.get(:__do_not_cache_query__) == true
      assert Provider.get(@cache_name, "nocache_key") == nil
    end

    test "with {:error, reason} returns error, doesn't cache" do
      result =
        Provider.get_or_store(
          @cache_name,
          "error_key",
          fn -> {:error, "failure"} end,
          &identity_middleware/3
        )

      assert result == {:error, "failure"}
      assert Provider.get(@cache_name, "error_key") == nil
    end
  end

  describe "count/1" do
    test "returns 0 for empty cache" do
      assert Provider.count(@cache_name) == 0
    end

    test "returns correct count after stores" do
      Provider.store(@cache_name, "c1", {:ok, 1})
      Provider.store(@cache_name, "c2", {:ok, 2})
      Provider.store(@cache_name, "c3", {:ok, 3})

      assert Provider.count(@cache_name) == 3
    end
  end

  describe "size/1" do
    test "returns a non-negative float" do
      size = Provider.size(@cache_name)
      assert is_float(size)
      assert size >= 0.0
    end
  end

  describe "clear_all/1" do
    test "removes all entries" do
      Provider.store(@cache_name, "d1", {:ok, 1})
      Provider.store(@cache_name, "d2", {:ok, 2})
      assert Provider.count(@cache_name) == 2

      Provider.clear_all(@cache_name)
      assert Provider.count(@cache_name) == 0
    end
  end

  describe "{key, ttl} tuple key" do
    test "stores and retrieves by same tuple key" do
      Provider.store(@cache_name, {"ttl_key", 60}, {:ok, "with_ttl"})
      assert Provider.get(@cache_name, {"ttl_key", 60}) == {:ok, "with_ttl"}
    end

    test "TTL above max_cache_ttl (7200) is clamped, not rejected" do
      Provider.store(@cache_name, {"big_ttl", 99_999}, {:ok, "big"})
      assert Provider.get(@cache_name, {"big_ttl", 99_999}) == {:ok, "big"}
    end

    test "get_or_store works with {key, ttl} tuple keys" do
      result =
        Provider.get_or_store(
          @cache_name,
          {"gos_ttl", 60},
          fn -> {:ok, "ttl_computed"} end,
          &identity_middleware/3
        )

      assert result == {:ok, "ttl_computed"}
      assert Provider.get(@cache_name, {"gos_ttl", 60}) == {:ok, "ttl_computed"}
    end
  end

  describe "store/3 overwrite" do
    test "storing to the same key overwrites the value" do
      Provider.store(@cache_name, "ow_key", {:ok, "first"})
      assert Provider.get(@cache_name, "ow_key") == {:ok, "first"}

      Provider.store(@cache_name, "ow_key", {:ok, "second"})
      assert Provider.get(@cache_name, "ow_key") == {:ok, "second"}
    end
  end

  describe "clear_all/1 returns :ok" do
    test "returns :ok on empty cache" do
      assert Provider.clear_all(@cache_name) == :ok
    end

    test "returns :ok on non-empty cache" do
      Provider.store(@cache_name, "clr_ret", {:ok, 1})
      assert Provider.clear_all(@cache_name) == :ok
    end
  end

  describe "concurrent get_or_store (thundering herd)" do
    test "function executes only once under concurrent access" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        Process.sleep(50)
        {:ok, "concurrent_val"}
      end

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Provider.get_or_store(@cache_name, "herd_key", fun, &identity_middleware/3)
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, &(&1 == {:ok, "concurrent_val"}))
      assert :counters.get(call_count, 1) == 1
    end
  end
end
