# Warnings de Dialyzer ignorados a propósito. Cada entrada debe justificarse.
[
  # Falso positivo en el código que genera la macro `use Gettext.Backend` (plural/opaque);
  # no está en nuestro código.
  {"lib/eth_web/gettext.ex", :call_without_opaque}
]
