defmodule AbsintheCache.BeforeSend do
  @moduledoc ~s"""
  Cache & Persist API Call Data right before sending the response.

  This module is responsible for persisting the whole result of some queries
  right before it is send to the client.

  All queries that did not raise exceptions and were successfully handled
  by the GraphQL layer pass through this module.

  The Blueprint's `result` field contains the final result as a single map.
  This result is made up of the top-level resolver and all custom resolvers.

  Caching the end result instead of each resolver separately allows to
  resolve the whole query with a single cache call - some queries could have
  thousands of custom resolver invocations.

  In order to cache a result all of the following conditions must be true:
  - All queries must be present in the `@cached_queries` list
  - The resolved value must not be an error
  - During resolving there must not be any `:nocache` returned.

  Most of the simple queries use 1 cache call and won't benefit from this approach.
  Only queries with many resolvers are included in the list of allowed queries.
  """

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @cached_queries Keyword.get(opts, :cached_queries, [])
      @context_cache_key Keyword.get(opts, :context_cache_key, :query_cache_key)

      def before_send(conn, %Absinthe.Blueprint{} = blueprint) do
        # Do not cache in case of:
        # -`:nocache` returned from a resolver
        # - result is taken from the cache and should not be stored again. Storing
        # it again `touch`es it and the TTL timer is restarted. This can lead
        # to infinite storing the same value if there are enough requests

        queries = queries_in_request(blueprint)
        do_not_cache? = Process.get(:__do_not_cache_query__) != nil

        case do_not_cache? or has_graphql_errors?(blueprint) do
          true -> :ok
          false -> cache_result(queries, blueprint)
        end

        conn
      end

      defp cache_result(queries, blueprint) do
        all_queries_cacheable? = queries |> Enum.all?(&Enum.member?(@cached_queries, &1))

        if all_queries_cacheable? do
          case get_cache_key(blueprint) do
            nil -> :ok
            cache_key -> AbsintheCache.store(cache_key, blueprint.result)
          end
        end
      end

      # The cache_key is the format of `{key, ttl}` or just `key`. Both cache keys
      # will be stored under the name `key` and in the first case only the ttl is
      # changed. This also means that if a value is stored as `{key, 300}` it can be
      # retrieved by using `{key, 10}` as in the case of `get` the ttl is ignored.
      # This allows us to change the cache_key produced in the DocumentProvider
      # and store it with a different ttl. The ttl is changed from the graphql cache
      # in case `caching_params` is provided.
      defp get_cache_key(blueprint) do
        case get_in(blueprint, [Access.key(:execution), Access.key(:context)]) do
          %{} = context ->
            case Map.get(context, @context_cache_key) do
              nil ->
                nil

              query_cache_key ->
                case Process.get(:__change_absinthe_before_send_caching_ttl__) do
                  ttl when is_number(ttl) ->
                    {cache_key, _old_ttl} = query_cache_key
                    {cache_key, ttl}

                  _ ->
                    query_cache_key
                end
            end

          _ ->
            nil
        end
      end

      defp queries_in_request(%{operations: operations}) do
        operations
        |> Enum.flat_map(fn %{selections: selections} ->
          selections
          |> Enum.map(fn %{name: name} -> Inflex.camelize(name, :lower) end)
        end)
      end

      defp has_graphql_errors?(%Absinthe.Blueprint{result: %{errors: _}}), do: true
      defp has_graphql_errors?(_), do: false
    end
  end
end
