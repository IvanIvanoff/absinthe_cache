# AbsintheCache

Caching solution for the Elixir's [GraphQL](http://spec.graphql.org/) server [Absinthe](https://github.com/absinthe-graphql/absinthe).

Goals:

- Easy to use.
- Easy to change the cache backend used.
- Flexible and configurable for the more complicated cases.
- Do not use config files.

## Why use AbsintheCache

- No other full-blown solution currently exists.
- Production tested.
- Easy to start using - just start the cache backend (using [con_cache](https://github.com/sasa1977/con_cache) by default) and replace the `resolve` macro with `cache_resolve`.
- `cache_resolve` provides out of the box support for resolvers that do not immediately return a result, but are using `async` or `dataloader`.
- Solves the problem of executing many resolvers for one query <sup> 1 </sup>.
- Pluggable cache backend. You do not like `con_cache` or want to use `Redis` so the cache is shared between multiple nodes? Just implement a behavior with 5 functions

> <sup> 1 </sup> A query that returns a list of 1000 objects with each of them running 3 resolvers, the query will have in total `1 + 1000 * 3 = 3001` resolvers being run. Even if these resolvers are cached, this means that 3001 cache calls have to be made. In order to solve this issue, `AbsintheCache` allows you to plug in the request's processing pipeline, skip the whole resolution phase and inject the final result directly. The final result is the result after all resolvers have run.

## Production tested

The cache implementation has been used at [Santiment](https://santiment.net/) since April 2018 serving 20 million requests per month. Ceasing support of the library is not expected.

## Functionality

`AbsintheCache` provides two major features:

- Cache a single resolver by changing the `resolve` macro to `cache_resolve`.
- Cache the result of the whole query execution at once.

## Examples

Full repo example can be found [here](https://github.com/IvanIvanoff/absinthe_cache_example)

---

### Example 1

**Problem**: There is a function `MetricResolver.get_metadata/3` that returns the metadata for a given metric. This function takes a lot of time to compute as it fetches data from three different databases and from elasticsearch. The solution to this is to cache it for 5 minutes.

In order to cache the resolver the following steps must be done:

First, the cache backend needs to be started in the supervision tree:

```elixir
# TODO: Abstract & improve
Supervisor.child_spec(
  {ConCache,
    [
      name: :graphql_cache,
      ttl_check_interval: :timer.seconds(30),
      global_ttl: :timer.minutes(5),
      acquire_lock_timeout: 30_000
    ]},
  id: :api_cache
)
```

This is where the cached data is persisted. It's important that the name of the cache is `:graphql_cache` as this is currently hardcoded in the implementation (will be improved)

Then the new resolve macros need to be imported.

```elixir
import AbsintheCache, only: [cache_resolve: 1, cache_resolve: 2]
```

`resolve` can now be replaced with `cache_resolve`:

```elixir
field :metric_metadata, :metric_metadata do
  arg(:metric, non_null(:string))
  resolve(&MetricResolver.get_metadata/3)
end
```

becomes:

```elixir
field :metric_metadata, :metric_metadata do
  arg(:metric, non_null(:string))
  cache_resolve(&MetricResolver.get_metadata/3)
end
```

There are two options to configure the TTL (time to live):

```elixir
field :metric_metadata, :metric_metadata do
  arg(:metric, non_null(:string))
  resolve(&MetricResolver.get_metadata/3, ttl: 60, max_ttl_offset: 60)
end
```

- :ttl - For how long (in seconds) should the value be cached. Defaults to 300 seconds.
- :max_ttl_offset - Extend the TTL with a random number of seconds in the interval `[0; max_ttl_offset]`. The value is not completely random - it will be the same for the same resolver and arguments pairs. This is useful in avoiding [cache stampede](https://en.wikipedia.org/wiki/Cache_stampede) problems. Defaults to 120 seconds.

### Example 2

**Problem**: There is a query `get_users` which returns a list of `:user`s. The USD balance of a user is computed by the `usd_balance/3` function. The problem is that the balance is needed in some special cases only, so it is not a good idea to always compute it and fill it in `get_users/3`. On the other hand, when we return big lists of users (over 1000), the `usd_balance/3` function will be called once for every user. Even if we use `cache_resolve`, processing the query will make 1000 calls to the cache to fill all the data. It would be nice to be able to fill all this data at once, wouldn't it? Let's explore how this can be done. Here is the schema:

```elixir
object :user do
  field(:id, non_null(:id))
  field(:email, :string)
  field(:username, :string)
  ...
  field :usd_balance, :integer do
    resolve(&UserResolver.usd_balance/3)
  end
end

field :get_users, list_of(:user) do
  resolve(&UserResolver.get_users/3)
end
```

The first step is defining which queries are to be cached. This is done in the following way:

```elixir
defmodule MyAppWeb.Graphql.AbsintheBeforeSend do
  use AbsintheCache.BeforeSend, cached_queries: ["get_users"]
end
```

Then you need to decide for how long to cache them:

```elixir

defmodule MyAppWeb.Graphql.DocumentProvider do
  use AbsintheCache.DocumentProvider, ttl: 300, max_ttl_offset: 120
end
```

Those modules are actually doing a lot more than just defining queries and ttl options.
To understand what really happens check the Internals section

The next step is modifying the Absinthe route in the router file - the `:document_providers` and `:before_send` keys need to be updated to:

```elixir
forward(
  ...
  document_providers: [
    AbsintheCache.DocumentProvider,
    Absinthe.Plug.DocumentProvider.Default
  ],
  ...
  before_send: {MyAppWeb.Graphql.AbsintheBeforeSend, :before_send}
  ...
)
```

## Internals

### How does `cache_resolve` work

TODO

### How does caching of the whole query execution work

TODO

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `absinthe_cache` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:absinthe_cache, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/absinthe_cache](https://hexdocs.pm/absinthe_cache).
