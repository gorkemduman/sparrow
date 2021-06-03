defmodule Sparrow.HNS.V1.TokenBearer do
  @moduledoc """
  Module providing HNS token.
  """

  require Logger

  @spec get_token(String.t()) :: String.t() | nil
  def get_token(account) do
    {:ok, token_map} =
      Huth.Token.for_scope(
        {account, "https://oauth-login.cloud.huawei.com/oauth"}
      )

    _ =
      Logger.debug("Fetching HNS token",
        worker: :hns_token_bearer,
        what: :get_token,
        result: :success
      )

    Map.get(token_map, :token)
  end

  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(raw_hns_config) do
    json =
      raw_hns_config
      |> IO.inspect()
      |> Enum.map(&decode_config/1)
      |> IO.inspect()
      |> Jason.encode!()

    _ =
      Logger.debug("Starting HNS TokenBearer",
        worker: :hns_token_bearer,
        what: :start_link,
        result: :success
      )

    Application.put_env(:huth, :json, json)
    Huth.Supervisor.start_link()
  end

  defp decode_config(config) do
    config[:path_to_json]
    |> IO.inspect
    |> File.read!()
    |> Jason.decode!()
  end
end
