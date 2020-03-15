defmodule AbsintheCache do
  @moduledoc ~s"""
  Provides the macro `cache_resolve` that replaces the Absinthe's `resolve` and
  caches the result of the resolver for some time instead of calculating it
  every time.
  """
  require Logger

  @ttl 300
  @max_ttl_offset 120

  # TODO: Configurable
  @cache_name :graphql_cache

  @compile :inline_list_funcs
  @compile {:inline,
            __from__: 2,
            wrap: 2,
            wrap: 3,
            resolver: 3,
            store: 2,
            store: 3,
            get_or_store: 2,
            get_or_store: 3,
            cache_modify_middleware: 3,
            cache_key: 2,
            convert_values: 2}

  alias __MODULE__, as: CacheMod
  # TODO: Make configurable
  alias AbsintheCache.ConCacheProvider, as: CacheProvider

  @doc ~s"""
  A drop-in replace of the `resolve` macro provided by `use Absinthe.Schema.Notation`
  that stores the result and subsequent calls fetch the value from the cache.

  This resolver can perform the following operations:
  - Get the stored value if there is one. The resolver function is not evaluated
  at all in this case.
  - Evaluate the resolver function and store the value in the cache.
  - Handle the `Absinthe.Middlewar.Async` and `Absinthe.Middleware.Dataloader`
  middlewares.

  There are two options for the passed function:
  1. It can be a captured named function because its name is extracted
  and used in the cache key.
  2. If the function is anonymous or a different name should be used, a second
  parameter with that name must be passed.

  Just like `resolve`, `cache_resolve` supports the `{:ok, value}` and `{:error, reason}`
  result tuples. The `:ok` tuples are cached while the `:error` tuples are not.

  `cache_resolve` handles a third type of response format.
  When `{:nocache, {:ok, value}}` is returned as the result the cache does **not**
  cache the value and just returns `{:ok, value}`. This is useful when the result
  can't be constructed but returning an error will crash the whole query.
  In such cases a default/filling value can be passed (0, nil, "No data", etc.)
  and the next query will try to resolve it again.

  Options:
  - :ttl - Override the base default TTL (time-to-live) of 300 seconds, used
  to compute the cache duration. The total duration is the TTL plus some random value
  - :max_ttl_offset - Override the default maximum TTL offset of 120 seconds.
  A random integer value between 0 and max_ttl_offset is added to the base TTL
  to derive the full duration of the cache.
  - :additonal_args_fun - 1-arity function accepting the %Absinthe.Resolution{}
  struct used to provide additonal arguments that will be passed to the function
  computing the cache key
  - :fun_name - Provide a name in case of anonymous function passed to the resolver
  or to change the name of the provided captured named function.
  """

  defmacro cache_resolve(captured_mfa_ast, opts \\ []) do
    quote do
      middleware(
        Absinthe.Resolution,
        CacheMod.__from__(unquote(captured_mfa_ast), unquote(opts))
      )
    end
  end

  @doc ~s"""
  Given a 0-arity function, return another 0-arity function that wraps the
  original in such a way that:
  - On execution checks if the value is present in the cache and returns it.
  - If it's not in the cache it gets executed and the value is stored in the cache.

  Arguments:
  - cache_fun - The 0-arity function to be cached
  - name - Name for the function to be used only for deriving the key
  - args - Args for the function to be used only for deriving the cache key
  - opts - Options passed to the cache key. :ttl and :max_ttl_offset are also
  supported with the same meaning as in `cache_resolve/3`

  NOTE: `cache_fun` is a function with arity 0. That means if you want to use it
  in your code and you want some arguments you should use it like this:
     Cache.wrap(
       fn -> fetch_last_price_record(pair) end,
       :fetch_price_last_record, %{pair: pair}
     ).()
  """
  @spec wrap((() -> t), name, args, Keyword.t()) :: (() -> t)
        when t: any(), name: any(), args: any()
  def wrap(cache_fun, name, args \\ %{}, opts \\ []) do
    fn ->
      CacheProvider.get_or_store(
        @cache_name,
        cache_key(name, args, opts),
        cache_fun,
        &cache_modify_middleware/3
      )
    end
  end

  @doc ~s"""
  Clears the whole cache.
  """
  def clear_all() do
    CacheProvider.clear_all(@cache_name)
  end

  @doc ~s"""
  The size of the cache in megabytes
  """
  def size() do
    CacheProvider.size(@cache_name, :megabytes)
  end

  def get(key) do
    CacheProvider.get(@cache_name, key)
  end

  def store(cache_name \\ @cache_name, cache_key, value) do
    CacheProvider.store(cache_name, cache_key, value)
  end

  def cache_key(name, args, opts \\ []) do
    base_ttl = Keyword.get(opts, :ttl, @ttl)
    max_ttl_offset = Keyword.get(opts, :max_ttl_offset, @max_ttl_offset)

    # The TTL is the base TTL + a random value in the interval [0; max_ttl_offset]
    # This is helpful in scenarios where a list of returned objects has cached fields
    # In order to avoid all caches expiring at the same time, adding a random
    # offset will rougly make it so on average max_ttl_offset / ttl_check_interval
    # percent of the fields will expire
    ttl = base_ttl + ({name, args} |> :erlang.phash2(max_ttl_offset))

    args = args |> convert_values(ttl)
    cache_key = {name, args} |> :erlang.phash2()

    {cache_key, ttl}
  end

  @doc false
  def __from__(captured_mfa, opts) when is_function(captured_mfa) do
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
    root_key = Keyword.get(opts, :root_key, :id)
    additional_args_fun = Keyword.get(opts, :additional_args_fun, fn _ -> nil end)

    # Works only for top-level resolvers and fields with root object that has `id` field
    fn
      %{^root_key => key} = root, args, resolution ->
        fun = fn -> resolver_fn.(root, args, resolution) end
        additional_args = additional_args_fun.(resolution)

        cache_key({name, key, resolution.source, additional_args}, args, opts)
        |> get_or_store(fun)

      %{}, args, resolution ->
        fun = fn -> resolver_fn.(%{}, args, resolution) end
        additional_args = additional_args_fun.(resolution)

        cache_key({name, resolution.source, additional_args}, args, opts)
        |> get_or_store(fun)
    end
  end

  defp get_or_store(cache_name \\ @cache_name, cache_key, resolver_fn) do
    CacheProvider.get_or_store(
      cache_name,
      cache_key,
      resolver_fn,
      &cache_modify_middleware/3
    )
  end

  # `cache_modify_middleware` is called only from withing `get_or_store` that
  # guarantees that it will be executed only once if it is accessed concurently.
  # This is way it is safe to use `store` explicitly without worrying about race
  # conditions
  defp cache_modify_middleware(cache_name, cache_key, {:ok, value} = result) do
    CacheProvider.store(cache_name, cache_key, result)

    {:ok, value}
  end

  defp cache_modify_middleware(
         cache_name,
         cache_key,
         {:middleware, Absinthe.Middleware.Async = midl, {fun, opts}}
       ) do
    caching_fun = fn ->
      CacheProvider.get_or_store(cache_name, cache_key, fun, &cache_modify_middleware/3)
    end

    {:middleware, midl, {caching_fun, opts}}
  end

  defp cache_modify_middleware(
         cache_name,
         cache_key,
         {:middleware, Absinthe.Middleware.Dataloader = midl, {loader, callback}}
       ) do
    caching_callback = fn loader_arg ->
      CacheProvider.get_or_store(
        cache_name,
        cache_key,
        fn -> callback.(loader_arg) end,
        &cache_modify_middleware/3
      )
    end

    {:middleware, midl, {loader, caching_callback}}
  end

  # Convert the values for using in the cache. A special treatement is done for
  # `%DateTime{}` so all datetimes in a @ttl sized window are treated the same
  defp convert_values(%DateTime{} = v, ttl), do: div(DateTime.to_unix(v, :second), ttl)
  defp convert_values(%_{} = v, _), do: Map.from_struct(v)

  defp convert_values(args, ttl) when is_list(args) or is_map(args) do
    args
    |> Enum.map(fn
      {k, v} -> [k, convert_values(v, ttl)]
      data -> convert_values(data, ttl)
    end)
  end

  defp convert_values(v, _), do: v
end
