defmodule AbsintheCache.MixProject do
  use Mix.Project

  def project do
    [
      app: :absinthe_cache,
      version: "0.1.0",
      package: package(),
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:absinthe, "~> 1.4"},
      {:inflex, "~> 2.0.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package() do
    [
      description: "Provides caching functionality on top of Absinthe GraphQL Server",
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* ),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/IvanIvanoff/absinthe_cache"}
    ]
  end
end
