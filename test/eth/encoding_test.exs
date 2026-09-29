defmodule Eth.EncodingTest do
  @moduledoc """
  Red de seguridad para el entorno Windows: detecta texto UTF-8 doblemente codificado
  (p. ej. "pÃ¡ginas" en lugar de "páginas") en código, tests, traducciones y docs.
  """
  use ExUnit.Case, async: true

  @globs [
    "lib/**/*.{ex,heex}",
    "test/**/*.{ex,exs}",
    "priv/gettext/**/*.{po,pot}",
    "docs/**/*.md",
    "*.md"
  ]

  # "Ã" o "Â" seguidos de un byte de continuación son la firma típica del mojibake.
  @mojibake ~r/[ÃÂ][\x{0080}-\x{00BF}]/u

  test "ningún archivo de texto tiene UTF-8 doblemente codificado" do
    offenders =
      for glob <- @globs,
          path <- Path.wildcard(glob),
          path != __ENV__.file |> Path.relative_to_cwd(),
          File.read!(path) =~ @mojibake,
          do: path

    assert offenders == [], "Archivos con mojibake: #{Enum.join(offenders, ", ")}"
  end
end
