defmodule Membrane.Core.Element do
  @moduledoc false

  # Module containing functions spawning, shutting down, inspecting and controlling
  # playback of elements. These functions are usually called by `Membrane.Pipeline`
  # or `Membrane.Bin`.
  #
  # Modules in this namespace are responsible for managing elements: handling incoming
  # data, executing callbacks and evaluating actions. These modules can be divided
  # in terms of functionality in the following way:
  # - Controllers handle messages received from other elements or calls from other
  #   controllers and handlers
  # - Handlers handle actions invoked by element itself
  # - Models contain some utility functions for accessing data in state
  # - `Membrane.Core.Element.State` defines the state struct that these modules
  #   operate on.

  use Bunch
  use GenServer

  import Membrane.Helper.GenServer

  alias Membrane.{Clock, Element, Sync}
  alias Membrane.Core.Element.{LifecycleController, PlaybackBuffer, State}
  alias Membrane.Core.{Message, PlaybackHandler, Telemetry, TimerController}
  alias Membrane.ComponentPath
  alias Membrane.Core.Child.PadController

  require Membrane.Core.Message
  require Membrane.Core.Telemetry
  require Membrane.Logger

  @type options_t :: %{
          module: module,
          name: Element.name_t(),
          user_options: Element.options_t(),
          sync: Sync.t(),
          parent: pid,
          parent_clock: Clock.t(),
          log_metadata: Keyword.t()
        }

  @doc """
  Starts process for element of given module, initialized with given options and
  links it to the current process in the supervision tree.

  Calls `GenServer.start_link/3` underneath.
  """
  @spec start_link(options_t, GenServer.options()) :: GenServer.on_start()
  def start_link(options, process_options \\ []),
    do: start_link(node(), options, process_options)

  @spec start_link(node(), options_t, GenServer.options()) :: GenServer.on_start()
  def start_link(node, options, process_options) when is_atom(node),
    do: do_start(node, :start_link, options, process_options)

  @doc """
  Works similarly to `start_link/5`, but does not link to the current process.
  """
  @spec start(options_t, GenServer.options()) :: GenServer.on_start()
  def start(options, process_options \\ []),
    do: start(node(), options, process_options)

  @spec start(node(), options_t, GenServer.options()) :: GenServer.on_start()
  def start(node, options, process_options),
    do: do_start(node, :start, options, process_options)

  defp do_start(node, method, options, process_options) do
    %{module: module, name: name, user_options: user_options} = options

    if Element.element?(options.module) do
      Membrane.Logger.debug("""
      Element #{method}: #{inspect(name)}
      node: #{node},
      module: #{inspect(module)},
      element options: #{inspect(user_options)},
      process options: #{inspect(process_options)}
      """)

      # rpc if necessary
      if node == node() do
        apply(GenServer, method, [__MODULE__, options, process_options])
      else
        :rpc.call(node, GenServer, method, [__MODULE__, options, process_options])
      end
    else
      raise """
      Cannot start element, passed module #{inspect(module)} is not a Membrane Element.
      Make sure that given module is the right one and it uses Membrane.{Source | Filter | Sink}
      """
    end
  end

  @doc """
  Stops given element process.

  It will wait for reply for amount of time passed as second argument
  (in milliseconds).

  Will trigger calling `c:Membrane.Element.Base.handle_shutdown/1`
  callback.
  """
  @spec shutdown(pid, timeout) :: :ok
  def shutdown(server, timeout \\ 5000) do
    GenServer.stop(server, :normal, timeout)
    :ok
  end

  @impl GenServer
  def init(options) do
    Process.monitor(options.parent)
    name_str = if String.valid?(options.name), do: options.name, else: inspect(options.name)
    :ok = Membrane.Logger.set_prefix(name_str)
    :ok = Logger.metadata(options.log_metadata)
    :ok = ComponentPath.set_and_append(options.log_metadata[:parent_path] || [], name_str)

    Telemetry.report_init(:element)

    state = Map.take(options, [:module, :name, :parent_clock, :sync, :parent]) |> State.new()

    with {:ok, state} <- LifecycleController.handle_init(options.user_options, state) do
      {:ok, state}
    else
      {{:error, reason}, _state} -> {:stop, {:element_init, reason}}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    Telemetry.report_terminate(:element)

    {:ok, _state} = LifecycleController.handle_shutdown(reason, state)

    :ok
  end

  @impl GenServer
  def handle_call(Message.new(:get_clock), _from, state) do
    reply({{:ok, state.synchronization.clock}, state})
  end

  @impl GenServer
  def handle_call(Message.new(:linking_finished), _from, state) do
    PadController.handle_linking_finished(state) |> reply(state)
  end

  @impl GenServer
  def handle_call(
        Message.new(:handle_link, [direction, this, other, other_info]),
        _from,
        state
      ) do
    PadController.handle_link(direction, this, other, other_info, state) |> reply(state)
  end

  @impl GenServer
  def handle_call(Message.new(:set_stream_sync, sync), _from, state) do
    new_state = put_in(state.synchronization.stream_sync, sync)
    reply({:ok, new_state})
  end

  @impl GenServer
  def handle_call(message, _from, state) do
    {{:error, {:invalid_message, message, mode: :call}}, state}
    |> reply(state)
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, parent_pid, reason}, %{parent_pid: parent_pid} = state) do
    {:ok, state} = LifecycleController.handle_pipeline_down(reason, state)

    {:stop, {:shutdown, :parent_crash}, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    Telemetry.report_metric(
      :queue_len,
      :erlang.process_info(self(), :message_queue_len) |> elem(1)
    )

    do_handle_info(message, state)
  end

  @compile {:inline, do_handle_info: 2}

  defp do_handle_info(Message.new(:change_playback_state, new_playback_state), state) do
    PlaybackHandler.change_playback_state(new_playback_state, LifecycleController, state)
    |> noreply(state)
  end

  defp do_handle_info(Message.new(type, _args, _opts) = msg, state)
       when type in [:demand, :buffer, :caps, :event] do
    PlaybackBuffer.store(msg, state) |> noreply(state)
  end

  defp do_handle_info(Message.new(:push_mode_announcement, [], for_pad: ref), state) do
    PadController.enable_toilet_if_pull(ref, state) |> noreply(state)
  end

  defp do_handle_info(Message.new(:handle_unlink, pad_ref), state) do
    PadController.handle_unlink(pad_ref, state) |> noreply(state)
  end

  defp do_handle_info(Message.new(:timer_tick, timer_id), state) do
    TimerController.handle_tick(timer_id, state) |> noreply(state)
  end

  defp do_handle_info({:membrane_clock_ratio, clock, ratio}, state) do
    TimerController.handle_clock_update(clock, ratio, state) |> noreply()
  end

  defp do_handle_info(Message.new(:log_metadata, metadata), state) do
    :ok = Logger.metadata(metadata)
    noreply({:ok, state})
  end

  defp do_handle_info(Message.new(_, _, _) = message, state) do
    {{:error, {:invalid_message, message, mode: :info}}, state}
    |> noreply(state)
  end

  defp do_handle_info(message, state) do
    LifecycleController.handle_other(message, state) |> noreply(state)
  end
end
