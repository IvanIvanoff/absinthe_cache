# Start the cache provider once for the test run
{:ok, _} =
  AbsintheCache.ConCacheProvider.start_link(
    id: :graphql_cache,
    name: :graphql_cache,
    ttl_check_interval: 30,
    global_ttl: 300
  )

ExUnit.start()
