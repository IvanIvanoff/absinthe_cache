defmodule AbsintheCache.TestCase do
  use ExUnit.CaseTemplate

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, true)

    quote do
      use ExUnit.Case, async: unquote(async)
      # import (not use) so we control ExUnit.Case and async; Plug.Test/Plug.Conn
      # provide conn/2, put_req_header/3, etc. needed for HTTP tests.
      import Plug.Test
      import Plug.Conn

      import unquote(__MODULE__)

      setup do
        # Start the GraphQL in-memory cache
        {:ok, cache_pid} =
          ConCache.start_link(name: :graphql_cache, ttl_check_interval: 30, global_ttl: 300)

        # Silently kill the cache before ending the test
        on_exit(fn -> ExUnit.CaptureLog.capture_log(fn -> Process.exit(cache_pid, :kill) end) end)
        %{cache_pid: cache_pid}
      end
    end
  end

  def call(conn, opts) do
    conn
    |> plug_parser
    |> Absinthe.Plug.call(opts)
    |> Map.update!(:resp_body, &Jason.decode!/1)
  end

  def plug_parser(conn) do
    opts =
      Plug.Parsers.init(
        parsers: [:urlencoded, :multipart, :json, Absinthe.Plug.Parser],
        json_decoder: Jason
      )

    Plug.Parsers.call(conn, opts)
  end
end
