defmodule AbsintheCache.DocumentProvider do
  @moduledoc ~s"""
  Custom Absinthe DocumentProvider for more effective caching.

  Absinthe phases have one main difference in comparison to plugs - all phases
  must run and cannot be halted. But phases can be jumped over by returning
  `{:jump, result, destination_phase}`

  This module makes use of 2 new phases - a `CacheDocument` phase and `Idempotent`
  phase.

  If the value is present in the cache, it is put in the blueprint and the execution
  jumps to the `Idempotent` phase, effectively skipping the Absinthe's `Resolution`
  and Result phases. Result is the last phase in the pipeline, thus the Idempotent
  phase is inserted after it.

  If the value is not present in the cache, the Absinthe's default `Resolution` and
  `Result` phases are being executed and the new `DocumentCache` and `Idempotent`
  phases are no-op.

  Finally, there's a `before_send` hook that adds the result into the cache.
  """

  defmodule Idempotent do
    @moduledoc ~s"""
    A no-op phase inserted after the Absinthe's `Result` phase.
    If the needed value is found in the cache, `CacheDocument` phase jumps to
    `Idempotent` one so the Absinthe's `Resolution` and `Result` phases are skipped.
    """
    use Absinthe.Phase
    @spec run(Absinthe.Blueprint.t(), Keyword.t()) :: Absinthe.Phase.result_t()
    def run(bp_root, _), do: {:ok, bp_root}
  end

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour Absinthe.Plug.DocumentProvider

      @doc false
      @impl true
      def pipeline(%Absinthe.Plug.Request.Query{pipeline: pipeline}) do
        pipeline
        |> Absinthe.Pipeline.insert_before(
          Absinthe.Phase.Document.Execution.Resolution,
          __MODULE__.CacheDocument
        )
        |> Absinthe.Pipeline.insert_after(
          Absinthe.Phase.Document.Result,
          AbsintheCache.DocumentProvider.Idempotent
        )
      end

      @doc false
      @impl true
      def process(%Absinthe.Plug.Request.Query{document: nil} = query, _), do: {:cont, query}
      def process(%Absinthe.Plug.Request.Query{document: _} = query, _), do: {:halt, query}

      defmodule CacheDocument do
        @moduledoc ~s"""
        Custom phase for obtaining the result from cache.
        In case the value is not present in the cache, the default `Resolution` and
        `Result` phases are run. Otherwise the custom `Resolution` phase is run and
        `Result` is jumped over.

        When calculating the cache key only some of the fields of the whole blueprint
        are used. They are defined in the module attribute @cache_fields. The only
        values that are converted to something else in the process of construction
        of the cache key are:
        - DateTime - It is rounded by TTL so all datetiems in a range yield the same
         cache key
        - Struct - All structs are converted to plain maps
        """

        use Absinthe.Phase

        @compile :inline_list_funcs
        @compile inline: [add_cache_key_to_context: 2, cache_key_from_params: 2]

        # Access opts from the surrounding `AbsintheCache.DocumentProvider` module
        @ttl Keyword.get(opts, :ttl, 120)
        @max_ttl_ffset Keyword.get(opts, :max_ttl_offset, 60)
        @cache_key_fun Keyword.get(
                         opts,
                         :additional_cache_key_args_fun,
                         &__MODULE__.additional_cache_key_args_fun_default/1
                       )

        def additional_cache_key_args_fun_default(_), do: :ok

        @spec run(Absinthe.Blueprint.t(), Keyword.t()) :: Absinthe.Phase.result_t()
        def run(bp_root, _) do
          additional_args = @cache_key_fun.(bp_root)

          cache_key =
            AbsintheCache.cache_key(
              {"bp_root", additional_args} |> :erlang.phash2(),
              sanitize_blueprint(bp_root),
              ttl: @ttl,
              max_ttl_offset: @max_ttl_ffset
            )

          bp_root = add_cache_key_to_context(bp_root, cache_key)

          case AbsintheCache.get(cache_key) do
            nil ->
              {:ok, bp_root}

            result ->
              # Storing it again `touch`es it and the TTL timer is restarted.
              # This can lead to infinite storing the same value
              Process.put(:do_not_cache_query, true)

              {:jump, %{bp_root | result: result}, AbsintheCache.DocumentProvider.Idempotent}
          end
        end

        # TODO: Make this function configurable
        defp add_cache_key_to_context(
               %{execution: %{context: context} = execution} = blueprint,
               cache_key
             ) do
          %{
            blueprint
            | execution: %{execution | context: Map.put(context, :query_cache_key, cache_key)}
          }
        end

        defp add_cache_key_to_context(bp, _), do: bp

        # Leave only the fields that are needed to generate the cache key.
        # This allows us to cache with values that are interpolated into the query
        # string itself. The datetimes are rounded so all datetimes in a bucket
        # generate the same cache key.
        defp sanitize_blueprint(%DateTime{} = dt), do: dt
        defp sanitize_blueprint({:argument_data, _} = tuple), do: tuple
        defp sanitize_blueprint({a, b}), do: {a, sanitize_blueprint(b)}

        @cache_fields [
          :name,
          :argument_data,
          :selection_set,
          :selections,
          :fragments,
          :operations,
          :alias
        ]
        defp sanitize_blueprint(map) when is_map(map) do
          Map.take(map, @cache_fields)
          |> Enum.map(&sanitize_blueprint/1)
          |> Map.new()
        end

        defp sanitize_blueprint(list) when is_list(list) do
          Enum.map(list, &sanitize_blueprint/1)
        end

        defp sanitize_blueprint(data), do: data

        # Extract the query and variables from the params map and genenrate
        # a cache key using them.

        # The query is fetched as is.
        # The variables that are valid datetime types (have the `from` or `to` name
        # and valid value) are converted to Elixir DateTime type prior to being used.
        # This is done because the datetimes are rounded so all datetimes in a N minute
        # buckets have the same cache key.

        # The other param types are not cast as they would be used the same way in both
        # places where the cache key is calculated.
        defp cache_key_from_params(params, permissions) do
          query = Map.get(params, "query", "")

          variables =
            case Map.get(params, "variables") do
              map when is_map(map) -> map
              vars when is_binary(vars) and vars != "" -> vars |> Jason.decode!()
              _ -> %{}
            end
            |> Enum.map(fn
              {key, value} when is_binary(value) ->
                case DateTime.from_iso8601(value) do
                  {:ok, datetime, _} -> {key, datetime}
                  _ -> {key, value}
                end

              pair ->
                pair
            end)
            |> Map.new()

          AbsintheCache.cache_key({query, permissions}, variables,
            ttl: @ttl,
            max_ttl_offset: @max_ttl_ffset
          )
        end
      end
    end
  end
end
