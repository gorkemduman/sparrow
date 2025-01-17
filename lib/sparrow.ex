defmodule Sparrow do
  @moduledoc """
  Sparrow is service providing ability to send push
  notification to `FCM` (Firebase Cloud Messaging) and/or
  `APNS` (Apple Push Notification Service).
  """
  use Application

  def start(_type, _args) do
    raw_fcm_config = Application.get_env(:sparrow, :fcm)
    raw_apns_config = Application.get_env(:sparrow, :apns)
    raw_hns_config = Application.get_env(:sparrow, :hns)
    start({raw_fcm_config, raw_apns_config, raw_hns_config})
  end

  @spec start({Keyword.t(), Keyword.t()}) :: Supervisor.on_start()
  def start({raw_fcm_config, raw_apns_config, raw_hns_config}) do
    %{:enabled => is_enabled} =
      Application.get_env(:sparrow, Sparrow.PoolsWarden)

    children =
      is_enabled
      |> maybe_start_pools_warden()
      |> maybe_append({Sparrow.FCM.V1.Supervisor, raw_fcm_config})
      |> maybe_append({Sparrow.APNS.Supervisor, raw_apns_config})
      |> maybe_append({Sparrow.HNS.V1.Supervisor , raw_hns_config})

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  @spec maybe_append([any], {any, nil | list}) :: [any]
  defp maybe_append(list, {_, nil}), do: list
  defp maybe_append(list, elem), do: list ++ [elem]

  defp maybe_start_pools_warden(true), do: [Sparrow.PoolsWarden]
  defp maybe_start_pools_warden(false), do: []
end
