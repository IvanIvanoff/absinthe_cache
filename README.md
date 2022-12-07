# AbsintheCache

This project is in an early development phase. This is the extracted version of the caching layer developed at [sanbase](https://github.com/santiment/sanbase2). There are still parts that are connected with its original repository and there are still parts that are not configurable enough. All these things are going to change.

This repository might not be updated often as the place where it originated has still not moved to using this as a library. The code is in active use, bug reports are going to be addressed and pull requests are welcomed.

---

Caching solution for the Elixir's [GraphQL](http://spec.graphql.org/) server [Absinthe](https://github.com/absinthe-graphql/absinthe).

Goals:

- Easy to use.
- Easy to change the cache backend used.
- Flexible and configurable for the more complicated cases.
- Do not use config files.

## Why use AbsintheCache

- Production tested.
- Easy to start using - just start the cache backend (integrated [cachex](https://github.com/whitfin/cachex) and [con_cache](https://github.com/sasa1977/con_cache)) and replace the `resolve` macro with `cache_resolve`.
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

### Example I

**Problem**

---

The `MetricResolver.get_metadata/3` function returns the metadata for a given metric. It takes a lot of time to compute as it fetches data from three different databases and from elasticsearch. The solution to this is to cache it for 5 minutes.

**Solution**

---

Cache the result for 5 minutes.

**Steps**

---

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
  cache_resolve(&MetricResolver.get_metadata/3, ttl: 60, max_ttl_offset: 60)
end
```

- :ttl - For how long (in seconds) should the value be cached. Defaults to 300 seconds.
- :max_ttl_offset - Extend the TTL with a random number of seconds in the interval `[0; max_ttl_offset]`. The value is not completely random - it will be the same for the same resolver and arguments pairs. This is useful in avoiding [cache stampede](https://en.wikipedia.org/wiki/Cache_stampede) problems. Defaults to 120 seconds.

### Example II

**Problem**

---

The `get_users` query returns `list_of(:user)`. The USD balance of a user is computed by the `usd_balance/3` function.The balance is needed in some special cases only, so it is not a good idea to always compute it and fill it in `get_users/3`. When we return big lists of users, the `usd_balance/3` function will be called once for every user. Even if we use dataloader and compute the result wiht a single query, in the end there would be thousands of function invocations (or cache calls if we also use `cache_resolve`) which would slow down the execution

**Solution**

---

Compute the data and cache the result **after** all resolvers are finished. This way the next query that hits the cache will make a single cache call to load all the data.

**Steps**

---

Let's have the query and types definition as follows:

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
    MyAppWeb.Graphql.DocumentProvider,
    Absinthe.Plug.DocumentProvider.Default
  ],
  ...
  before_send: {MyAppWeb.Graphql.AbsintheBeforeSend, :before_send}
  ...
)
```

## Internals

### How does `cache_resolve` work

Following is a high level overview of the internal working of `cache_resolve`. For complete understaning please read the source code.

`cache_resolve` works by wrapping the function that computes the result. The wrapper computes a cache key from the function name and arguments (if anonymous function is passed then a function name must be explicitly given). The wrapper function checks for a stored value
corresponding to the cache key. If there is such - the value is returned and the function computation is skipped, thus avoiding running a slow function. If there is not a stored value - the function
is comptued, the value is stored in the cache under the given cache key and the result is returned.
If `async` or `dataloader` are used the approach is the same excluding some imlementation details. In both cases there is a zero or one arity
functions that can be wrapped and cached.
If there are many concurrent requests for the same query only one process will acquire a lock and run the actual computations. The other processes will wait on the lock and get the computed data once it's ready.

### How does caching of the whole query execution work

The work here is split into two major parts - a custom [DocumentProvider](https://hexdocs.pm/absinthe_plug/Absinthe.Plug.DocumentProvider.html) and a [before send hook](https://hexdocs.pm/absinthe_plug/Absinthe.Plug.html#module-before-send).
Shortly said, the document provider sets up the pipeline of phases that are going to run (around 40 of them) and the before send hook is usually used to modify the Plug connection right before the result is being sent.

The default document provider has two phases that are importat to `AbsintheCache` - the Resolution phase and the Result phase - these are the phases where the resolvers run and the result is constructed.

The custom document provider defines the same pipeline as the default one but inserts two extra phases - Cache phrase is inserted before the Resolution phase and Idempotent phase is inserted after Result phase (usually the last one).

The Cache phase constructs a cache key out of the query name, arguments and variables in a smart way - it can work both with interpolated variables in the query string and by separately passed variables. If the constructed cache key has a corresponding cached value it is taken and the execution "jumps" over the Resolution and Result phases directly to the Idempotent phase that does nothing. It is needed because the Result phase is the last one but the Cache needs to jump right after it.

The before send hook is executed after all phases have run. If computed value has not been taken from the cache, this is the step where it is inserted into the cache. It's done here because we need the "constructed" result after all resolvers are run and their results are merged into one. The cached value is actually a json string - the result that is sent to the client. Storing it in this form allows the execution to totally skip the resolution and result building phases.

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
