defmodule Sparrow.H2Worker.Hns do
  @moduledoc false
  use GenServer
  use Sparrow.Telemetry.Timer

  require Logger

  alias Sparrow.H2ClientAdapter.Chatterbox.Hns, as: Adapter
  alias Sparrow.H2Worker.Config
  alias Sparrow.H2Worker.RequestSet
  alias Sparrow.H2Worker.RequestState, as: InnerRequest
  alias Sparrow.H2Worker.State

  @type gen_server_name :: atom
  @type config :: Sparrow.H2Worker.Config.t()
  @type on_start ::
          {:ok, pid} | :ignore | {:error, {:already_started, pid} | term}
  @type init_args :: [any]
  @type state :: Sparrow.H2Worker.State.t()
  @type stream_id :: non_neg_integer
  @type reason :: any
  @type incomming_message ::
          :ping
          | {:PONG, pid}
          | {charlist, stream_id}
          | {:timeout_request, stream_id}
          | any
  @type request :: Sparrow.H2Worker.Request.t()
  @type from :: {pid, tag :: term}
  @type headers :: [{String.t(), String.t()}]
  @type body :: String.t()

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @spec init(config) :: {:ok, state, {:continue, term()}}
  def init(config) do
    config =
      config
      |> Config.get_authentication_type()
      |> case do
        :certificate_based ->
          tls_options = [
            {:certfile, config.authentication.certfile},
            {:keyfile, config.authentication.keyfile} | config.tls_options
          ]

          %{config | tls_options: tls_options}

        :token_based ->
          config
      end

    state = Sparrow.H2Worker.State.new(nil, config)

    :telemetry.execute(
      [:sparrow, :h2_worker, :init],
      %{},
      extract_worker_info(state)
    )

    {:ok, state, {:continue, :start_conn_backoff}}
  end

  @spec terminate(reason, state) :: :ok
  def terminate(reason, state = %State{connection_ref: nil}) do
    _ =
      Logger.info("Connection shutting down",
        what: :h2_connection_terminate,
        reason: inspect(reason),
        connection_ref: nil
      )

    :telemetry.execute(
      [:sparrow, :h2_worker, :terminate],
      %{},
      state
      |> extract_worker_info()
      |> Map.put(:reason, reason)
    )

    :ok
  end

  def terminate(reason, state) do
    Adapter.close(state.connection_ref)

    _ =
      Logger.info("Connection shutting down",
        what: :h2_connection_terminate,
        reason: inspect(reason),
        connection_ref: state.connection_ref
      )

    :telemetry.execute(
      [:sparrow, :h2_worker, :terminate],
      %{},
      state
      |> extract_worker_info()
      |> Map.put(:reason, reason)
    )

    :ok
  end

  @spec handle_continue(:start_conn_backoff, state) ::
          {:noreply, state} | {:stop, reason, state}
  def handle_continue(:start_conn_backoff, state = %State{config: config}) do
    {:noreply, state}
  end

  def handle_info(
        {:ping, connection_ref},
        state = %State{connection_ref: connection_ref}
      ) do
    {:noreply, state}
  end

  @spec handle_info(incomming_message, state) :: {:noreply, state}
  def handle_info({:ping, _}, state) do
    {:noreply, state}
  end

  def handle_info({:PONG, from}, state) do
    _ =
      Logger.debug("Received ping response",
        what: :ping_response,
        from: inspect(from)
      )

    {:noreply, state}
  end

#  def handle_info({:timeout_request, stream_id}, state) do
#    _ =handle_info
#      Logger.debug("H2 request timeout",
#        what: :h2_request_timeout,
#        stream_id: "#{stream_id}"
#      )
#
#    case RequestSet.get_request(state.requests, stream_id) do
#      {:error, :not_found} ->
#        :ok
#
#      {:ok, request} ->
#        response = {:error, {:request_timeout, stream_id}}
#        send_response(request.from, response)
#    end
#
#    {:noreply,
#     State.new(
#       state.connection_ref,
#       RequestSet.remove(state.requests, stream_id),
#       state.config
#     )}
#  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case state.connection_ref == pid do
      true ->
        _ =
          Logger.debug("Connection process down",
            what: :h2_connection_lost,
            pid: inspect(pid),
            reason: inspect(reason)
          )

        :telemetry.execute(
          [:sparrow, :h2_worker, :conn_lost],
          %{},
          state
          |> extract_worker_info()
          |> Map.put(:reason, reason)
        )

        {:noreply, state}

      _ ->
        _ =
          Logger.warn("Unknown connection process down",
            what: :h2_unknown_down_message,
            pid: inspect(pid),
            reason: inspect(reason)
          )

        {:noreply, state}
    end
  end

  def handle_info(
        {:start_conn, try_count, delay_stream},
        state = %State{connection_ref: nil}
      ) do
    {:noreply, try_start_conn(state, try_count, delay_stream)}
  end

  def handle_info({:start_conn, _, _}, state) do
    {:noreply, %State{state | restart_connection_timer: nil}}
  end

  def handle_info(unknown, state) do
    _ = Logger.warn("Unknown info message", what: :unknown_info, value: unknown)
    {:noreply, state}
  end

  @doc !"""
       When connection closes, all requests in progress are teriminated with error.
       """
  @spec connection_closed_action(state) :: state
  defp connection_closed_action(state) do
    state.requests
    |> Map.to_list()
    |> Enum.each(fn {_, req} ->
      GenServer.reply(req.from, {:error, :connection_lost})
    end)

    state
    |> State.reset_connection_ref()
    |> State.reset_requests_collection()
  end

  def is_alive_connection(pid) do
    GenServer.call(pid, :is_alive_connection)
  end

  def handle_call(:is_alive_connection, _from, state) do
    {:reply, state.connection_ref != nil, state}
  end

  @spec handle_call({:send_request, request}, from, state) ::
          {:noreply, state} | {:stop, reason, state}
  def handle_call({:send_request, request}, from, state) do
    _ =
      Logger.debug("Attempt to send HTTP request",
        what: :h2_request_attempt,
        type: :call,
        request: request,
        from: inspect(from),
        state: state
      )

    try_handle(request, from, state)
  end

  @spec handle_cast({:send_request, request}, state) ::
          {:stop, reason, state} | {:noreply, state}
  def handle_cast({:send_request, request}, state) do
    _ =
      Logger.debug("Attempt to send HTTP request",
        what: :h2_request_attempt,
        type: :cast,
        request: request,
        state: state
      )

    try_handle(request, :noreply, state)
  end

  @spec try_handle(request, from | :noreply, state) ::
          {:stop, reason, state} | {:noreply, state}
  defp try_handle(request, from, state = %State{connection_ref: nil}) do
    _ =
      Logger.debug("No need connection for new request",
        what: :h2_restarting_conn_on_new_request,
        request: request
      )
      handle(request, from, state)
  end

  defp try_handle(request, from, state) do
    handle(request, from, state)
  end

  @doc !"""
       Tries to send request, schedulates timeout for it and adds it to state.
       """
  @timed event_tags: [:h2_worker, :handle]
  @spec handle(request, from | :noreply, state) :: {:noreply, state}
  defp handle(request, from, state) do
    headers =
      case Config.get_authentication_type(state.config) do
        :certificate_based ->
          request.headers

        :token_based ->
          token_header = state.config.authentication.token_getter.()

          _ =
            Logger.debug("Auth token added to request headers",
              what: :add_token_to_headers,
              result: :success,
              token_header: inspect(token_header)
            )

          [token_header | request.headers]
      end

    post_result =
      Adapter.post(
        state.connection_ref,
        state.config.domain,
        request.path,
        headers,
        request.body
      )

    case post_result do
      {:error, return_code} ->
        _ =
          Logger.warn("Failed to send H2 request",
            what: :h2_request_failed,
            request: request,
            status: :error,
            reason: "#{return_code}"
          )

        :telemetry.execute(
          [:sparrow, :h2_worker, :request_error],
          %{},
          state
          |> extract_worker_info()
          |> Map.put(:from, from)
          |> Map.put(:return_code, return_code)
        )

        send_response(from, {:error, return_code})
        {:noreply, state}

      {:ok, {headers, body}} ->
        :telemetry.execute(
          [:sparrow, :h2_worker, :request_success],
          %{},
          extract_worker_info(state)
        )

        send_response(from, {:ok, {headers, body}})
        {:noreply, state}
    end
  end

  @doc !"""
       Scheduales message to genserver after time miliseconds.
       When time is nil scheduling is ignored.
       """
  @spec schedule_message_after(any, nil | non_neg_integer) :: reference
  defp schedule_message_after(_message, nil) do
    :ok
  end

  defp schedule_message_after(message, time) do
    _ =
      Logger.debug("Scheduling H2 connection message",
        what: :h2_schedule_message,
        message: inspect(message),
        after: inspect(time)
      )

    :erlang.send_after(floor(time), self(), message)
  end

  @doc !"""
       Used for sending response to genserver call.
       """
  @spec send_response(
          :noreply | {pid(), any},
          {:error,
           :not_ready
           | byte()
           | {:request_timeout, non_neg_integer()}
           | {:unable_to_connect, term()}}
          | {:ok, {[any()], binary()}}
        ) :: :ok
  defp send_response(:noreply, response) do
    _ =
      Logger.debug("Sending response to caller",
        what: :h2_send_reponse,
        to: nil,
        response: inspect(response)
      )

    :ok
  end

  defp send_response(addressee, {:ok, {headers, body}}) do
    _ =
      Logger.debug("Sending response to caller",
        what: :h2_send_reponse,
        to: inspect(addressee),
        headers: inspect(headers),
        body: "#{body}"
      )

    GenServer.reply(addressee, {:ok, {headers, body}})
  end

  defp send_response(addressee, {:error, reason}) do
    case reason do
      {:request_timeout, stream_id} ->
        _ =
          Logger.warn("Sending response to caller",
            what: :h2_send_reponse,
            item: :request_response,
            stream_id: "#{stream_id}",
            status: :error,
            reason: :timeout
          )

        GenServer.reply(addressee, {:error, :request_timeout})

      :not_ready ->
        _ =
          Logger.error("Sending response to caller",
            what: :h2_send_reponse,
            status: :error,
            reason: :response_not_ready
          )

        GenServer.reply(addressee, {:error, :not_ready})

      other_reason ->
        _ =
          Logger.error("Sending response to caller",
            what: :h2_send_reponse,
            status: :error,
            reason: inspect(other_reason)
          )

        GenServer.reply(addressee, {:error, other_reason})
    end
  end

  @doc !"""
       Used for canceling timeouts for succesfully received requests.
       """
  @spec cancel_timer(Sparrow.H2Worker.RequestState.t()) :: :ok
  defp cancel_timer(request) do
    canceling_result = :erlang.cancel_timer(request.timeout_reference)

    _ =
      Logger.debug("Canceling internal H2 timer",
        what: :h2_canceling_timer,
        result: inspect(canceling_result)
      )

    :ok
  end

  defp try_start_conn(state = %State{config: config}, try_count, delay_stream) do
    case start_conn(config) do
      {:ok, new_state} ->
        {:ok, delay} = Enum.fetch(delay_stream, try_count)

        :telemetry.execute(
          [:sparrow, :h2_worker, :conn_success],
          %{
            try_count: try_count,
            timer: delay
          },
          extract_worker_info(state)
        )

        %State{new_state | restart_connection_timer: nil}

      {:error, reason} ->
        {:ok, delay} = Enum.fetch(delay_stream, try_count)

        :telemetry.execute(
          [:sparrow, :h2_worker, :conn_fail],
          %{
            try_count: try_count,
            timer: delay
          },
          extract_worker_info(state)
        )

        _ =
          Logger.warn("Failed to start H2 connection",
            what: :h2_connection_start,
            status: :error,
            domain: config.domain,
            port: config.port,
            reason: inspect(reason),
            next_try_in: "#{delay}",
            tls_options: inspect(config.tls_options)
          )

        timer =
          schedule_message_after(
            {:start_conn, try_count + 1, delay_stream},
            delay
          )

        %State{state | restart_connection_timer: timer}
    end
  end

  defp start_conn(config, 0) do
    case start_conn(config) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        _ =
          Logger.error("",
            what: :starting_connection,
            domain: inspect(config.domain),
            port: inspect(config.port),
            tls_options: inspect(config.tls_options),
            restarts_left: "0"
          )

        {:error, reason}
    end
  end

  defp start_conn(config, restarts_left) when restarts_left > 0 do
    _ =
      Logger.debug("Starting H2 connection",
        what: :h2_starting_connection,
        domain: config.domain,
        port: config.port,
        tls_options: inspect(config.tls_options),
        restarts_left: restarts_left
      )

    case start_conn(config) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        _ =
          Logger.warn("Failed to start H2 connection",
            what: :h2_starting_connection,
            status: :error,
            reason: inspect(reason),
            domain: config.domain,
            port: config.port,
            tls_options: inspect(config.tls_options),
            restarts_left: restarts_left
          )

        start_conn(config, restarts_left - 1)
    end
  end

  defp start_conn(config) do
    case Adapter.open(config.domain, config.port, config.tls_options) do
      {:ok, _} ->
        {:ok, State.new(nil, nil, config)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_worker_info(worker_state) do
    config = worker_state.config

    %{
      domain: config.domain,
      port: config.port,
      pool_type: config.pool_type,
      pool_name: config.pool_name,
      pool_tags: config.pool_tags
    }
  end
end
