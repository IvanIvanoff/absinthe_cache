defmodule AbsintheCacheTest.TestDoubleProvider do
  @moduledoc """
  Test double that implements AbsintheCache.Behaviour and records all
  get/store/get_or_store calls so tests can assert the pluggable backend is used.
  """
  @behaviour AbsintheCache.Behaviour

  @impl AbsintheCache.Behaviour
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{cache: %{}, calls: []} end, name: name)
  end

  @impl AbsintheCache.Behaviour
  def child_spec(opts) do
    id = Keyword.get(opts, :id, __MODULE__)
    %{id: id, start: {__MODULE__, :start_link, [opts]}}
  end

  defp agent_name do
    Process.get({__MODULE__, :name}) || __MODULE__
  end

  @impl AbsintheCache.Behaviour
  def get(cache, key) do
    state = Agent.get(agent_name(), & &1)
    value = get_in(state.cache, [cache, key])
    if value == nil, do: nil, else: {:ok, value}
  end

  @impl AbsintheCache.Behaviour
  def store(cache, key, value) do
    Agent.update(agent_name(), fn state ->
      cache_map = Map.get(state.cache, cache, %{}) |> Map.put(key, value)
      calls = state.calls ++ [{:store, cache, key}]
      %{state | cache: Map.put(state.cache, cache, cache_map), calls: calls}
    end)
    :ok
  end

  @impl AbsintheCache.Behaviour
  def get_or_store(cache, key, func, middleware_func) do
    Agent.update(agent_name(), fn state ->
      updated_calls = state.calls ++ [{:get_or_store, cache, key}]
      %{state | calls: updated_calls}
    end)

    state = Agent.get(agent_name(), & &1)
    cached = get_in(state.cache, [cache, key])

    if cached != nil do
      cached
    else
      result = func.()
      _ = middleware_func.(cache, key, result)
      result
    end
  end

  @impl AbsintheCache.Behaviour
  def size(_cache), do: 0.0

  @impl AbsintheCache.Behaviour
  def count(cache) do
    state = Agent.get(agent_name(), & &1)
    (state.cache[cache] && map_size(state.cache[cache])) || 0
  end

  @impl AbsintheCache.Behaviour
  def clear_all(cache) do
    Agent.update(agent_name(), fn state ->
      %{state | cache: Map.delete(state.cache, cache)}
    end)
    :ok
  end

  def get_calls(pid_or_name \\ __MODULE__) do
    name = if is_pid(pid_or_name), do: pid_or_name, else: pid_or_name
    Agent.get(name, fn state -> state.calls end)
  end

  def clear_calls(pid_or_name \\ __MODULE__) do
    name = if is_pid(pid_or_name), do: pid_or_name, else: pid_or_name
    Agent.update(name, fn state -> %{state | calls: []} end)
    :ok
  end
end
