defmodule EthWeb.PageController do
  use EthWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
