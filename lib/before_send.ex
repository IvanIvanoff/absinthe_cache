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
      @compile :inline_list_funcs
      @compile inline: [cache_result: 2, queries_in_request: 1, has_graphql_errors?: 1]

      @cached_queries Keyword.get(opts, :cached_queries, [])
      def before_send(conn, %Absinthe.Blueprint{} = blueprint) do
        # Do not cache in case of:
        # -`:nocache` returned from a resolver
        # - result is taken from the cache and should not be stored again. Storing
        # it again `touch`es it and the TTL timer is restarted. This can lead
        # to infinite storing the same value if there are enough requests

        queries = queries_in_request(blueprint)
        do_not_cache? = Process.get(:do_not_cache_query) != nil

        case do_not_cache? or has_graphql_errors?(blueprint) do
          true -> :ok
          false -> cache_result(queries, blueprint)
        end

        conn
      end

      defp cache_result(queries, blueprint) do
        all_queries_cacheable? = queries |> Enum.all?(&Enum.member?(@cached_queries, &1))

        if all_queries_cacheable? do
          AbsintheCache.store(
            blueprint.execution.context.query_cache_key,
            blueprint.result
          )
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
