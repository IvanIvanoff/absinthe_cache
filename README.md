# AbsintheCache

Caching layer for the Elixir [Absinthe](https://github.com/absinthe-graphql/absinthe) GraphQL server.

Replace `resolve` with `cache_resolve` and your resolvers are cached. For queries with many resolvers, cache the entire query result in a single call by plugging into Absinthe's pipeline.

Production-tested at [Santiment](https://santiment.net/) since 2018, serving millions of requests per day.

## Features

- **Drop-in resolver caching** -- swap `resolve` for `cache_resolve`, everything else stays the same
- **Whole-query caching** -- skip the entire resolution phase on cache hits via a custom DocumentProvider
- **Thundering herd protection** -- concurrent requests for the same key share a single computation
- **Async & Dataloader support** -- `cache_resolve` handles `Absinthe.Middleware.Async` and `Dataloader` transparently
- **Pluggable backend** -- ships with [ConCache](https://github.com/sasa1977/con_cache) and [Cachex](https://github.com/whitfin/cachex) adapters, or implement `AbsintheCache.Behaviour` for your own (e.g. Redis)
- **TTL jitter** -- randomized TTL offset per resolver avoids [cache stampede](https://en.wikipedia.org/wiki/Cache_stampede) on expiry

## Installation

Add `absinthe_cache` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:absinthe_cache, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Start the cache in your supervision tree

```elixir
children = [
  AbsintheCache.child_spec(name: :graphql_cache, id: :graphql_cache)
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### 2. Import and use `cache_resolve`

```elixir
defmodule MyApp.Schema do
  use Absinthe.Schema
  import AbsintheCache, only: [cache_resolve: 1, cache_resolve: 2]

  query do
    field :expensive_data, :result do
      arg :id, non_null(:id)
      cache_resolve(&MyApp.Resolvers.get_expensive_data/3)
    end

    field :shorter_cache, :result do
      arg :id, non_null(:id)
      cache_resolve(&MyApp.Resolvers.get_expensive_data/3, ttl: 30, max_ttl_offset: 30)
    end
  end
end
```

That's it. The resolver result is cached for 5 minutes (default) with thundering herd protection.

## Configuration

All settings are optional. Defaults work out of the box.

```elixir
# config/config.exs
config :absinthe_cache,
  cache_name: :graphql_cache,           # registered name of the cache process
  cache_provider: AbsintheCache.ConCacheProvider,  # module implementing Behaviour
  ttl: 300,                             # base TTL in seconds (default: 5 min)
  max_ttl_offset: 120                   # random offset range in seconds (default: 2 min)
```

The effective TTL for each resolver is `ttl + offset` where `offset` is a deterministic value in `[0, max_ttl_offset]` derived from the resolver name and arguments. This spreads out cache expiry to prevent stampedes.

## Usage

### Resolver-level caching with `cache_resolve`

`cache_resolve` is a drop-in replacement for Absinthe's `resolve`:

```elixir
# Before
field :metric_metadata, :metric_metadata do
  arg :metric, non_null(:string)
  resolve(&MetricResolver.get_metadata/3)
end

# After
field :metric_metadata, :metric_metadata do
  arg :metric, non_null(:string)
  cache_resolve(&MetricResolver.get_metadata/3)
end
```

#### Options

```elixir
cache_resolve(&MetricResolver.get_metadata/3,
  ttl: 60,                       # override base TTL for this resolver
  max_ttl_offset: 30,            # override offset range
  honor_do_not_cache_flag: true  # skip cache when :__do_not_cache_query__ is set
)

field :eth_addresses, list_of(:eth_address) do
  cache_resolve(
    dataloader(SanbaseRepo),
    # Give a name to the anonymous function
    fun_name: :eth_addresses_resolver_fun
  )
end
```

#### Return values

| Return value | Behavior |
|---|---|
| `{:ok, value}` | Cached and returned |
| `{:error, reason}` | Returned as-is, **not cached** |
| `{:nocache, {:ok, value}}` | Returned as `{:ok, value}`, **not cached** |

The `{:nocache, ...}` tuple is useful when you want to return a placeholder value (e.g. `nil`, `0`, `"No data"`) without caching it, so the next request retries the computation. 
Note that returning `{:nocache, {:ok, value}}` is supported only for fields that use `cache_resolve/{1,2}`
and not for the defaults `resolve/1` macro.

### Whole-query caching

For queries with many resolvers (e.g. a list of 1000 items each with 3 field resolvers = 3001 resolver calls), you can cache the entire query result as a single entry. On cache hits, the Resolution and Result phases are skipped entirely.

#### 1. Define a DocumentProvider

```elixir
defmodule MyApp.DocumentProvider do
  use AbsintheCache.DocumentProvider,
    ttl: 300,
    max_ttl_offset: 120
end
```

#### 2. Define a BeforeSend hook

```elixir
defmodule MyApp.AbsintheBeforeSend do
  use AbsintheCache.BeforeSend,
    cached_queries: ["getUsers", "getMetrics"]
end
```

Only queries listed in `cached_queries` are cached. Query names should be in camelCase as they appear in the GraphQL request.

#### 3. Wire them up in your router

```elixir
forward "/api",
  Absinthe.Plug,
  schema: MyApp.Schema,
  document_providers: [
    MyApp.DocumentProvider,
    Absinthe.Plug.DocumentProvider.Default
  ],
  before_send: {MyApp.AbsintheBeforeSend, :before_send}
```

### Using `wrap` outside of schemas

`AbsintheCache.wrap/3,4` caches any zero-arity function, useful outside of Absinthe resolvers:

```elixir
AbsintheCache.wrap(
  fn -> MyApp.compute_expensive_value(pair) end,
  :compute_expensive_value,
  %{pair: pair}
).()
```

### Direct cache access

```elixir
AbsintheCache.store("my_key", {:ok, value})
AbsintheCache.get("my_key")
AbsintheCache.count()
AbsintheCache.size()     # in megabytes
AbsintheCache.clear_all()
```

Direct access can be useful in tests if there is need to clear the cache.

## Cache Backends

### ConCache (default)

Ships as a dependency. No extra setup needed.

```elixir
config :absinthe_cache,
  cache_provider: AbsintheCache.ConCacheProvider
```

### Cachex

Add `cachex` to your dependencies, then configure:

```elixir
config :absinthe_cache,
  cache_provider: AbsintheCache.CachexProvider
```

The Cachex adapter includes gzip compression of cached values and LRW eviction (removes 30% of least-recently-written keys when reaching 2M entries).

### Custom backend

Implement the `AbsintheCache.Behaviour` callbacks:

```elixir
defmodule MyApp.RedisCacheProvider do
  @behaviour AbsintheCache.Behaviour

  @impl true
  def start_link(opts), do: ...

  @impl true
  def child_spec(opts), do: ...

  @impl true
  def get(cache, key), do: ...

  @impl true
  def store(cache, key, value), do: ...

  @impl true
  def get_or_store(cache, key, fun, cache_modify_middleware), do: ...

  @impl true
  def size(cache), do: ...

  @impl true
  def count(cache), do: ...

  @impl true
  def clear_all(cache), do: ...
end
```

## How It Works

### Resolver caching

`cache_resolve` wraps the resolver function. On each call it:

1. Computes a cache key from the function name, arguments, and parent context
2. Checks the cache -- if hit, returns the value without calling the resolver
3. If miss, acquires a lock for that key (thundering herd protection)
4. Executes the resolver, stores `{:ok, value}` results, returns the result
5. Other processes waiting on the same key get the result once it's computed

### Whole-query caching

The DocumentProvider inserts a `CacheDocument` phase before Absinthe's Resolution phase and an `Idempotent` phase after the Result phase.

- **Cache hit**: `CacheDocument` injects the cached result and jumps to `Idempotent`, skipping Resolution and Result entirely
- **Cache miss**: `CacheDocument` is a no-op, resolution runs normally, and `BeforeSend` stores the final result

This means a cached query is served with a single cache lookup regardless of how many resolvers it contains.

## License

MIT
