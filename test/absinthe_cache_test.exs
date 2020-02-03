defmodule AbsintheCacheTest do
  defmodule Schema do
    use Absinthe.Schema
    import AbsintheCache, only: [cache_resolve: 1]

    require Logger

    query do
      field :get_name_cached, non_null(:string) do
        cache_resolve(fn _, _, _ ->
          Logger.info("PRINTING SOME DATA")
          {:ok, "Ivan"}
        end)
      end

      field :get_name_not_cached, non_null(:string) do
        resolve(fn _, _, _ ->
          Logger.info("PRINTING SOME DATA")
          {:ok, "Ivan"}
        end)
      end
    end
  end

  use AbsintheCache.TestCase, async: true

  import ExUnit.CaptureLog

  test "uncached function is called every time" do
    fun = fn ->
      Absinthe.run("{ getNameNotCached }", Schema, root_value: %{})
    end

    # Every time the rsolver is executed
    assert capture_log(fun) =~ "PRINTING SOME DATA"
    assert capture_log(fun) =~ "PRINTING SOME DATA"
    assert capture_log(fun) =~ "PRINTING SOME DATA"
    assert capture_log(fun) =~ "PRINTING SOME DATA"
    assert capture_log(fun) =~ "PRINTING SOME DATA"
  end

  test "cached function is called only the first time" do
    fun = fn ->
      Absinthe.run("{ getNameCached }", Schema, root_value: %{})
    end

    # Every time the rsolver is executed
    assert capture_log(fun) =~ "PRINTING SOME DATA"
    refute capture_log(fun) =~ "PRINTING SOME DATA"
    refute capture_log(fun) =~ "PRINTING SOME DATA"
    refute capture_log(fun) =~ "PRINTING SOME DATA"
    refute capture_log(fun) =~ "PRINTING SOME DATA"
  end
end
