defmodule AbsintheCache.TestCase do
  use ExUnit.CaseTemplate

  defmacro __using__(_) do
    quote do
      use ExUnit.Case, async: true
      use Plug.Test

      import unquote(__MODULE__)

      setup do
        # Cache started once in test_helper; clear between tests (config module = schema)
        AbsintheCache.clear_all(AbsintheCacheTest.Schema)
        :ok
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
