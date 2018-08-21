defmodule Helpers.CowboyHandlers.ConnectionHandler do
  def init(req, opts) do
    reply = :cowboy_req.reply(200, %{"content-type" => "text/plain; charset=utf-8"}, "Hello", req)
    {:ok, reply, opts}
  end
end