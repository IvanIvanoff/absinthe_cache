defmodule Schema do
  use Absinthe.Schema
  import AbsintheCache, only: [cache_resolve: 1]

  query do
    field :get_name, non_null(:string) do
      cache_resolve(fn _, _ ->
        {:ok, "Ivan"}
      end)
    end
  end
end
