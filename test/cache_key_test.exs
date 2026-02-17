defmodule AbsintheCache.CacheKeyTest do
  use AbsintheCache.TestCase, async: false

  describe "cache_key/3" do
    test "returns a {binary, integer} tuple" do
      {key, ttl} = AbsintheCache.cache_key(:my_resolver, %{})
      assert is_binary(key)
      assert is_integer(ttl)
    end

    test "same inputs produce same key when called quickly" do
      {key1, ttl1} = AbsintheCache.cache_key(:same_resolver, %{slug: "bitcoin"})
      {key2, ttl2} = AbsintheCache.cache_key(:same_resolver, %{slug: "bitcoin"})
      assert key1 == key2
      assert ttl1 == ttl2
    end

    test "different names produce different keys" do
      {key1, _} = AbsintheCache.cache_key(:resolver_a, %{})
      {key2, _} = AbsintheCache.cache_key(:resolver_b, %{})
      assert key1 != key2
    end

    test "different args produce different keys" do
      {key1, _} = AbsintheCache.cache_key(:resolver, %{slug: "bitcoin"})
      {key2, _} = AbsintheCache.cache_key(:resolver, %{slug: "ethereum"})
      assert key1 != key2
    end

    test "default TTL is between 300 and 420 (base 300 + 0..120 offset)" do
      {_key, ttl} = AbsintheCache.cache_key(:ttl_test, %{})
      assert ttl >= 300
      assert ttl <= 420
    end

    test "custom ttl: option is respected" do
      {_key, ttl} = AbsintheCache.cache_key(:custom_ttl, %{}, ttl: 600)
      # base is 600, max_ttl_offset defaults to 120, so ttl in [600, 720]
      assert ttl >= 600
      assert ttl <= 720
    end

    test "custom max_ttl_offset: option is respected" do
      {_key, ttl} = AbsintheCache.cache_key(:offset_test, %{}, ttl: 500, max_ttl_offset: 10)
      assert ttl >= 500
      assert ttl <= 510
    end

    test "caching_params in args overrides TTL" do
      args = %{caching_params: %{base_ttl: 1000, max_ttl_offset: 50}}
      {_key, ttl} = AbsintheCache.cache_key(:params_test, args)
      assert ttl >= 1000
      assert ttl <= 1050
    end

    test "caching_params sets :__change_absinthe_before_send_caching_ttl__ in process dict" do
      Process.delete(:__change_absinthe_before_send_caching_ttl__)
      args = %{caching_params: %{base_ttl: 800, max_ttl_offset: 10}}
      {_key, ttl} = AbsintheCache.cache_key(:before_send_test, args)
      stored = Process.get(:__change_absinthe_before_send_caching_ttl__)
      assert stored == ttl
    end

    test "DateTime values in args are bucketed — two datetimes seconds apart produce same key" do
      now = DateTime.utc_now()
      later = DateTime.add(now, 1, :second)

      {key1, _} = AbsintheCache.cache_key(:dt_test, %{from: now})
      {key2, _} = AbsintheCache.cache_key(:dt_test, %{from: later})
      assert key1 == key2
    end

    test "structs in args are converted via Map.from_struct — __struct__ key is stripped" do
      # Two structs of same type with same data produce same key
      uri1 = %URI{host: "example.com", path: "/api"}
      uri2 = %URI{host: "example.com", path: "/api"}

      {key1, _} = AbsintheCache.cache_key(:struct_test, %{source: uri1})
      {key2, _} = AbsintheCache.cache_key(:struct_test, %{source: uri2})
      assert key1 == key2

      # A struct with different data produces a different key
      uri3 = %URI{host: "other.com", path: "/api"}
      {key3, _} = AbsintheCache.cache_key(:struct_test, %{source: uri3})
      assert key1 != key3
    end
  end
end
