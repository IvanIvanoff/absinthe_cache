defmodule AbsintheCache do
  @moduledoc ~s"""
  Provides the macro `cache_resolve` that replaces Absinthe's `resolve` and
  caches the result of the resolver for some time instead of calculating it
  every time.

  ## Configuration

  All settings are optional and have sensible defaults:

      config :absinthe_cache,
        cache_name: :graphql_cache,
        cache_provider: AbsintheCache.ConCacheProvider,
        ttl: 300,
        max_ttl_offset: 120

  - `:cache_name` — the registered name of the cache process (default: `:graphql_cache`)
  - `:cache_provider` — module implementing `AbsintheCache.Behaviour` (default: `AbsintheCache.ConCacheProvider`)
  - `:ttl` — base time-to-live in seconds for cached entries (default: `300`)
  - `:max_ttl_offset` — maximum random offset added to TTL to avoid cache stampede (default: `120`)

  ## Process dictionary keys

  This library communicates between modules via the process dictionary:

  - `:__do_not_cache_query__` — when set to `true`, signals that the current query
    should not be cached. Set by providers when `{:nocache, {:ok, value}}` is returned,
    and by `DocumentProvider` on cache hits (to avoid re-storing). Read by `cache_resolve`
    (with `honor_do_not_cache_flag: true`) and `BeforeSend`.
  - `:__change_absinthe_before_send_caching_ttl__` — when `caching_params` are provided
    in the query args, this is set to the computed TTL. Read by `BeforeSend` to override
    the TTL when storing the full query result.
  """

  alias __MODULE__, as: CacheMod

  @default_ttl 300
  @default_max_ttl_offset 120

  defp cache_name, do: Application.get_env(:absinthe_cache, :cache_name, :graphql_cache)
  defp cache_provider, do: Application.get_env(:absinthe_cache, :cache_provider, AbsintheCache.ConCacheProvider)
  defp default_ttl, do: Application.get_env(:absinthe_cache, :ttl, @default_ttl)
  defp default_max_ttl_offset, do: Application.get_env(:absinthe_cache, :max_ttl_offset, @default_max_ttl_offset)

  @doc ~s"""
  Macro that's used instead of Absinthe's `resolve`. This resolver can perform
  the following operations:
  1. Get the value from a cache if it is persisted. The resolver function is not
  evaluated at all in this case
  2. Evaluate the resolver function and store the value in the cache if it is
  not present there
  3. Handle the `Absinthe.Middleware.Async` and `Absinthe.Middleware.Dataloader`
  middleware. In order to handle them, the function that executes the actual
  evaluation is wrapped in a function that handles the cache interactions

  There are 2 options for the passed function:
  1. It can be a captured named function because its name is extracted
  and used in the cache key.
  2. If the function is anonymous or a different name should be used, a second
  parameter with that name must be passed.

  Just like `resolve` coming from Absinthe, `cache_resolve` supports the `{:ok, value}`
  and `{:error, reason}` result tuples. The `:ok` tuples are cached while the `:error`
  tuples are not.

  But `cache_resolve` knows how to handle a third type of response format. When
  `{:nocache, {:ok, value}}` is returned as the result the cache does **not** cache
  the value and just returns `{:ok, value}`. This is particularly useful when
  the result can't be constructed but returning an error will crash the whole query.
  In such cases a default/filling value can be passed (0, nil, "No data", etc.)
  and the next query will try to resolve it again.
  """

  defmacro cache_resolve(captured_mfa_ast, opts \\ []) do
    quote do
      middleware(
        Absinthe.Resolution,
        CacheMod.from(unquote(captured_mfa_ast), unquote(opts))
      )
    end
  end

  @doc ~s"""
  Exposed because it can sometimes be useful outside the macros.

  Takes a function, name, and arguments and returns a new function that:
  1. On execution checks if the value is present in the cache and returns it
  2. If it's not in the cache it gets executed and the value is stored in the cache.

  NOTE: `cached_func` is a function with arity 0. That means if you want to use it
  in your code and you want some arguments you should use it like this:
    > Cache.wrap(
    >   fn ->
    >     fetch_last_price_record(pair)
    >   end,
    >   :fetch_price_last_record, %{pair: pair}
    > ).()
  """
  def wrap(cached_func, name, args \\ %{}, opts \\ []) do
    fn ->
      cache_provider().get_or_store(
        cache_name(),
        cache_key(name, args, opts),
        cached_func,
        &cache_modify_middleware/3
      )
    end
  end

  def child_spec(opts) do
    cache_provider().child_spec(opts)
  end

  @doc ~s"""
  Clears the whole cache.
  """
  def clear_all() do
    cache_provider().clear_all(cache_name())
  end

  @doc ~s"""
  The size of the cache in megabytes.
  """
  def size() do
    cache_provider().size(cache_name())
  end

  @doc ~s"""
  The number of entries in the cache.
  """
  def count() do
    cache_provider().count(cache_name())
  end

  def get(key) do
    cache_provider().get(cache_name(), key)
  end

  @doc false
  def from(captured_mfa, opts) when is_function(captured_mfa) do
    # Public so it can be used by the resolve macros. You should not use it.
    case Keyword.pop(opts, :fun_name) do
      {nil, opts} ->
        fun_name = captured_mfa |> :erlang.fun_info() |> Keyword.get(:name)
        resolver(captured_mfa, fun_name, opts)

      {fun_name, opts} ->
        resolver(captured_mfa, fun_name, opts)
    end
  end

  # Private functions

  defp resolver(resolver_fn, name, opts) do
    fn
      %{} = root, args, resolution ->
        fun = fn -> resolver_fn.(root, args, resolution) end

        # by default use only :id from the root
        root_keys = Keyword.get(opts, :root_keys, [:id])
        additional_args = Map.take(root, root_keys)

        # resolution.source contains the arguments passed to a parent object
        # in order to properly cache timeseries data in the query
        # {getMetric(metric: "nvt") {timeseriesData(...)}}
        # the key must include `metric` from the parent's args
        args_from_source = generate_additional_args(resolution.source)

        cache_key = cache_key({name, additional_args, args_from_source}, args, opts)

        # In some edge-cases the caching can be disabled for some reason. In one
        # particular case for all_projects_by_function the caching is disabled
        # (by putting the do_not_cache_query: true Process dictionary key-value)
        # if the base_projects depends on a watchlist. The cache resolver that
        # is disabled must provide the `honor_do_not_cache_flag: true` explicitly,
        # so we are not disabling all of the caching, but only the one that matters
        skip_cache? =
          Keyword.get(opts, :honor_do_not_cache_flag, false) and
            Process.get(:__do_not_cache_query__) == true

        case skip_cache? do
          true -> fun.()
          false -> get_or_store(cache_key, fun)
        end
    end
  end

  defp generate_additional_args(data) do
    case data do
      %{id: id} -> id
      %{slug: slug} -> slug
      %{word: word} -> word
      _ -> data
    end
  end

  def store(cache_key, value), do: store(cache_name(), cache_key, value)

  def store(cache_name, cache_key, value) do
    cache_provider().store(cache_name, cache_key, value)
  end

  def get_or_store(cache_key, resolver_fn), do: get_or_store(cache_name(), cache_key, resolver_fn)

  def get_or_store(cache_name, cache_key, resolver_fn) do
    cache_provider().get_or_store(
      cache_name,
      cache_key,
      resolver_fn,
      &cache_modify_middleware/3
    )
  end

  # `cache_modify_middleware` is called only from within `get_or_store` that
  # guarantees that it will be executed only once if it is accessed concurrently.
  # This is why it is safe to use `store` explicitly without worrying about race
  # conditions.
  defp cache_modify_middleware(cache_name, cache_key, {:ok, value} = result) do
    cache_provider().store(cache_name, cache_key, result)

    {:ok, value}
  end

  defp cache_modify_middleware(
         cache_name,
         cache_key,
         {:middleware, Absinthe.Middleware.Async = midl, {fun, opts}}
       ) do
    caching_fun = fn ->
      cache_provider().get_or_store(cache_name, cache_key, fun, &cache_modify_middleware/3)
    end

    {:middleware, midl, {caching_fun, opts}}
  end

  defp cache_modify_middleware(
         cache_name,
         cache_key,
         {:middleware, Absinthe.Middleware.Dataloader = midl, {loader, callback}}
       ) do
    caching_callback = fn loader_arg ->
      cache_provider().get_or_store(
        cache_name,
        cache_key,
        fn -> callback.(loader_arg) end,
        &cache_modify_middleware/3
      )
    end

    {:middleware, midl, {loader, caching_callback}}
  end

  # Helper functions

  def cache_key(name, args, opts \\ []) do
    base_ttl = args[:caching_params][:base_ttl] || Keyword.get(opts, :ttl, default_ttl())

    max_ttl_offset =
      args[:caching_params][:max_ttl_offset] ||
        Keyword.get(opts, :max_ttl_offset, default_max_ttl_offset())

    base_ttl = max(base_ttl, 1)
    max_ttl_offset = max(max_ttl_offset, 1)

    # Used to randomize the TTL for lists of objects like list of projects
    additional_args = Map.take(args, [:slug, :id])

    # Using phash2 as a random number between 0 and max_ttl_offset is needed.
    # collisions are allowed and do not lead to errors
    ttl = base_ttl + ({name, additional_args} |> :erlang.phash2(max_ttl_offset))

    if args[:caching_params] do
      # This is used in the Absinthe's before_send function
      Process.put(:__change_absinthe_before_send_caching_ttl__, ttl)
    end

    args = args |> convert_values(ttl)

    # Bucket-based invalidation: include the current datetime bucket in the key so that
    # keys rotate over time. This relieves locking issues—if a process fails to release
    # a lock, the key will change after the bucket TTL (see below) and the lock becomes
    # irrelevant. Tradeoff: the same query can produce different keys in different
    # buckets, reducing cache hit rate near bucket boundaries. Bucket duration is
    # base_ttl + max_ttl_offset + phash2(..., 180), i.e. base_ttl + max_ttl_offset + 0..179
    # seconds, so buckets change roughly every (base_ttl + max_ttl_offset) seconds with
    # some jitter to avoid thundering herd.
    bucket_ttl = base_ttl + max_ttl_offset + :erlang.phash2({name, args}, 180)
    current_bucket = convert_values(DateTime.utc_now(), bucket_ttl)

    cache_key = {current_bucket, name, args} |> hash()

    {cache_key, ttl}
  end

  # Convert the values for using in the cache. A special treatment is done for
  # `%DateTime{}` so all datetimes in a TTL sized window are treated the same
  defp convert_values(%DateTime{} = v, ttl), do: div(DateTime.to_unix(v, :second), ttl)
  defp convert_values(%_{} = v, _), do: Map.from_struct(v)

  defp convert_values(args, ttl) when is_list(args) or is_map(args) do
    args
    |> Enum.map(fn
      {k, v} ->
        [k, convert_values(v, ttl)]

      data ->
        convert_values(data, ttl)
    end)
  end

  defp convert_values(v, _), do: v

  defp hash(data) do
    :crypto.hash(:sha256, :erlang.term_to_binary(data))
    |> Base.encode64()
  end
end
