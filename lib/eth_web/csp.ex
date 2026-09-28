defmodule EthWeb.CSP do
  @moduledoc """
  Content-Security-Policy de la aplicación.

  El único script inline es el que aplica el tema antes de pintar la página (evita el
  parpadeo claro/oscuro). Para no habilitar `'unsafe-inline'` en `script-src`, el script
  vive aquí y la política lo autoriza por su hash SHA-256, calculado en compilación: si
  el script cambia, el hash cambia con él.

  Implementa: RNF-4.8, RNF-5.1.
  """

  @theme_script """
  (() => {
    const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";

    const setTheme = (theme) => {
      if (theme === "system") {
        localStorage.removeItem("phx:theme");
        document.documentElement.setAttribute("data-theme", systemTheme());
        document.documentElement.setAttribute("data-theme-source", "system");
      } else {
        localStorage.setItem("phx:theme", theme);
        document.documentElement.setAttribute("data-theme", theme);
        document.documentElement.setAttribute("data-theme-source", "user");
      }
    };
    if (!document.documentElement.hasAttribute("data-theme")) {
      setTheme(localStorage.getItem("phx:theme") || "system");
    }
    window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));
    window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));

    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
      if (document.documentElement.getAttribute("data-theme-source") === "system") {
        document.documentElement.setAttribute("data-theme", systemTheme());
      }
    });
  })();
  """

  @theme_script_hash :sha256 |> :crypto.hash(@theme_script) |> Base.encode64()

  # style-src necesita 'unsafe-inline': LiveView y topbar aplican estilos inline.
  @policy Enum.join(
            [
              "default-src 'self'",
              "script-src 'self' 'sha256-#{@theme_script_hash}'",
              "style-src 'self' 'unsafe-inline'",
              "img-src 'self' data: https://images.evetech.net",
              "connect-src 'self'",
              "frame-src 'self'",
              "frame-ancestors 'self'",
              "base-uri 'self'",
              "form-action 'self' https://login.eveonline.com",
              "object-src 'none'"
            ],
            "; "
          )

  @doc "Script inline de tema (se renderiza sin modificar en `root.html.heex`)."
  @spec theme_script() :: String.t()
  def theme_script, do: @theme_script

  @doc """
  Etiqueta `<script>` con el script de tema, lista para el `<head>`.

  `raw/1` es seguro aquí: el contenido es una constante de compilación, nunca datos
  externos (por eso se omite la regla XSS.Raw de Sobelow solo en esta función).
  """
  # sobelow_skip ["XSS.Raw"]
  @spec theme_script_tag() :: Phoenix.HTML.safe()
  def theme_script_tag, do: Phoenix.HTML.raw("<script>" <> @theme_script <> "</script>")

  @doc "Valor de la cabecera `content-security-policy`."
  @spec policy() :: String.t()
  def policy, do: @policy
end
