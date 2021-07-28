defmodule Membrane.Core.Bin.LinkingBuffer do
  @moduledoc false
  use Membrane.Core.StateDispatcher

  alias Membrane.Core.Bin.State
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.{Message, StateDispatcher}
  alias Membrane.Pad

  require Message
  require Pad

  @type t :: %{Pad.name_t() => [Message.t()]}

  @doc """
  Creates a new linking buffer.
  """
  @spec new :: t()
  def new, do: Map.new()

  @doc """
  This function sends a message to pad, IF AND ONLY IF
  this pad is already linked. If it's not, it is stored
  and will be sent after calling `flush_for_pad()`.
  Params:
  * buf - buffer structure
  * msg - message to be sent
  * sender_pad - pad from which the message is supposed
                   to be sent
  * state - state of the bin
  """
  @spec store_or_send(Message.t(), Pad.ref_t(), State.t()) :: State.t()
  def store_or_send(msg, sender_pad, state) do
    buf = StateDispatcher.get_bin(state, :linking_buffer)

    with {:ok, %{pid: dest_pid, other_ref: other_ref}} <-
           PadModel.get_data(state, sender_pad),
         false <- currently_linking?(sender_pad, state) do
      send(dest_pid, Message.set_for_pad(msg, other_ref))
      state
    else
      _unknown_or_linking ->
        new_buf = Map.update(buf, sender_pad, [msg], &[msg | &1])
        StateDispatcher.update_bin(state, linking_buffer: new_buf)
    end
  end

  defp currently_linking?(pad, state),
    do: pad in StateDispatcher.get_bin(state, :pads).dynamic_currently_linking

  @doc """
  Sends messages stored for a given output pad.
  A link must already be available.
  """
  @spec flush_for_pad(Pad.ref_t(), State.t()) :: State.t()
  def flush_for_pad(pad, state) do
    buf = StateDispatcher.get_bin(state, :linking_buffer)

    case Map.pop(buf, pad, []) do
      {[], ^buf} ->
        state

      {msgs, new_buf} ->
        msgs |> Enum.reverse() |> Enum.each(&do_flush(&1, pad, state))
        StateDispatcher.update_bin(state, linking_buffer: new_buf)
    end
  end

  @spec flush_all_public_pads(State.t()) :: State.t()
  def flush_all_public_pads(state) do
    buf = StateDispatcher.get_bin(state, :linking_buffer)

    public_pads =
      buf
      |> Enum.map(fn {pad_ref, _msgs} -> pad_ref end)
      |> Enum.filter(&(&1 |> Pad.name_by_ref() |> Pad.is_public_name()))

    public_pads
    |> Enum.reduce(state, &flush_for_pad/2)
  end

  defp do_flush(msg, sender_pad, state) do
    {:ok, %{pid: dest_pid, other_ref: other_ref}} = PadModel.get_data(state, sender_pad)
    send(dest_pid, Message.set_for_pad(msg, other_ref))
  end
end
