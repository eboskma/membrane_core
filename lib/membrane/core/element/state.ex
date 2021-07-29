defmodule Membrane.Core.Element.State do
  @moduledoc false

  # Record representing state of an Core.Element. It is a part of the private API.
  # It does not represent state of elements you construct, it's a state used
  # internally in Membrane.

  use Bunch.Access

  alias Bunch.Type
  alias Membrane.{Clock, Element, Pad, Sync}
  alias Membrane.Core.{Playback, Timer}
  alias Membrane.Core.Child.{PadModel, PadSpecHandler}
  alias Membrane.Core.Element.PlaybackBuffer

  require Record
  require Membrane.Pad

  @type stateful_t(value) :: Type.stateful_t(value, t)
  @type stateful_try_t :: Type.stateful_try_t(t)
  @type stateful_try_t(value) :: Type.stateful_try_t(value, t)

  @type t ::
          record(
            :state,
            module: module,
            type: Element.type_t(),
            name: Element.name_t(),
            internal_state: Element.state_t() | nil,
            pads: PadModel.pads_t() | nil,
            watcher: pid | nil,
            controlling_pid: pid | nil,
            parent_monitor: reference() | nil,
            playback: Playback.t(),
            playback_buffer: PlaybackBuffer.t(),
            supplying_demand?: boolean(),
            delayed_demands: MapSet.t({Pad.ref_t(), :supply | :redemand}),
            synchronization: %{
              timers: %{Timer.id_t() => Timer.t()},
              parent_clock: Clock.t(),
              latency: non_neg_integer(),
              stream_sync: Sync.t(),
              clock: Clock.t() | nil
            }
          )

  Record.defrecord(:state, __MODULE__, [
    :module,
    :type,
    :name,
    :internal_state,
    :pads,
    :watcher,
    :controlling_pid,
    :parent_monitor,
    :playback,
    :playback_buffer,
    :supplying_demand?,
    :delayed_demands,
    :synchronization
  ])

  @doc """
  Initializes new state.
  """
  @spec new(%{
          module: module,
          name: Element.name_t(),
          parent_clock: Clock.t(),
          sync: Sync.t(),
          parent_monitor: reference()
        }) :: t
  def new(options) do
    state(
      module: options.module,
      type: options.module.membrane_element_type(),
      name: options.name,
      internal_state: nil,
      pads: nil,
      watcher: nil,
      controlling_pid: nil,
      parent_monitor: options[:parent_monitor],
      playback: %Playback{},
      playback_buffer: PlaybackBuffer.new(),
      supplying_demand?: false,
      delayed_demands: MapSet.new(),
      synchronization: %{
        parent_clock: options.parent_clock,
        timers: %{},
        clock: nil,
        stream_sync: options.sync,
        latency: 0
      }
    )
    |> PadSpecHandler.init_pads()
  end
end
