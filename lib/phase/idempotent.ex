defmodule AbsintheCache.Phase.Document.Idempotent do
  @moduledoc ~s"""
  A no-op phase inserted after the Absinthe's `Result` phase.
  If the needed value is found in the cache, `CacheDocument` phase jumps to
  `Idempotent` one so the Absinthe's `Resolution` and `Result` phases are skipped.
  """
  use Absinthe.Phase
  @spec run(Absinthe.Blueprint.t(), Keyword.t()) :: Absinthe.Phase.result_t()
  def run(bp_root, _), do: {:ok, bp_root}
end
