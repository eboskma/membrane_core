defmodule Membrane.Core.Element.BufferController do
  @moduledoc false

  # Module handling buffers incoming through input pads.

  use Bunch

  alias Membrane.{Buffer, Pad}
  alias Membrane.Core.{CallbackHandler, InputBuffer}
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.Element.{ActionHandler, DemandHandler, State}
  alias Membrane.Core.Telemetry
  alias Membrane.Element.CallbackContext

  require Membrane.Core.Child.PadModel
  require Membrane.Core.Telemetry

  @doc """
  Handles incoming buffer: either stores it in InputBuffer, or executes element's
  callback. Also calls `Membrane.Core.Element.DemandHandler.check_and_handle_demands/2`
  to check if there are any unsupplied demands.
  """
  @spec handle_buffer(Pad.ref_t(), [Buffer.t()] | Buffer.t(), State.t()) :: State.stateful_try_t()
  def handle_buffer(pad_ref, buffers, state) do
    PadModel.assert_data!(state, pad_ref, %{direction: :input})

    case PadModel.get_data!(state, pad_ref, :mode) do
      :pull -> handle_buffer_pull(pad_ref, buffers, state)
      :push -> exec_buffer_handler(pad_ref, buffers, state)
    end
  end

  @doc """
  Executes `handle_process` or `handle_write_list` callback.
  """
  @spec exec_buffer_handler(
          Pad.ref_t(),
          [Buffer.t()] | Buffer.t(),
          params :: map,
          State.t()
        ) :: State.stateful_try_t()
  def exec_buffer_handler(pad_ref, buffers, params \\ %{}, state)

  def exec_buffer_handler(pad_ref, buffers, params, %State{type: :filter} = state) do
    require CallbackContext.Process

    CallbackHandler.exec_and_handle_callback(
      :handle_process_list,
      ActionHandler,
      %{context: &CallbackContext.Process.from_state/1} |> Map.merge(params),
      [pad_ref, buffers],
      state
    )
  end

  def exec_buffer_handler(pad_ref, buffers, params, %State{type: :sink} = state) do
    require CallbackContext.Write

    Telemetry.report_metric(:buffer, length(List.wrap(buffers)))
    Telemetry.report_bitrate(buffers)

    CallbackHandler.exec_and_handle_callback(
      :handle_write_list,
      ActionHandler,
      %{context: &CallbackContext.Write.from_state/1} |> Map.merge(params),
      [pad_ref, buffers],
      state
    )
  end

  @spec handle_buffer_pull(Pad.ref_t(), [Buffer.t()] | Buffer.t(), State.t()) ::
          State.stateful_try_t()
  defp handle_buffer_pull(pad_ref, buffers, state) do
    PadModel.assert_data!(state, pad_ref, %{direction: :input})

    with {:ok, old_input_buf} <- PadModel.get_data(state, pad_ref, :input_buf) do
      input_buf = InputBuffer.store(old_input_buf, buffers)
      state = PadModel.set_data!(state, pad_ref, :input_buf, input_buf)

      if old_input_buf |> InputBuffer.empty?() do
        DemandHandler.supply_demand(pad_ref, state)
      else
        {:ok, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end
end
