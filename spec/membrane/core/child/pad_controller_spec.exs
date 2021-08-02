defmodule Membrane.Core.Child.PadControllerSpec do
  use ESpec, async: false

  alias Membrane.Core.Child.{PadModel, PadSpecHandler}
  alias Membrane.Core.Element.State
  alias Membrane.Core.Events.EndOfStream
  alias Membrane.Pad
  alias Membrane.Support.Element.{DynamicFilter, TrivialFilter}

  describe ".link_pad/7" do
    let :module, do: TrivialFilter
    let :name, do: :element_name

    let! :state do
      State.new(%{module: module(), name: name(), parent_clock: nil, sync: nil})
      |> PadSpecHandler.init_pads()
    end

    context "when pad is present in the element" do
      let :pad_ref, do: :output
      let :pad_name, do: :output
      let :direction, do: :output
      let :other_ref, do: :other_input
      let :other_info, do: %{}
      let :props, do: %{}

      it "should return an ok result with pad info" do
        pad_info = state().pads.info.output

        expect(
          described_module().handle_link(
            direction(),
            %{pad_ref: pad_ref(), pid: self(), pad_props: props()},
            %{pad_ref: other_ref(), pid: self()},
            other_info(),
            state()
          )
        )
        |> to(match_pattern {{:ok, ^pad_info}, _})
      end

      it "should not modify state except pads list" do
        {{:ok, _info}, new_state} =
          described_module().handle_link(
            direction(),
            %{pad_ref: pad_ref(), pid: self(), pad_props: props()},
            %{pad_ref: other_ref(), pid: self()},
            other_info(),
            state()
          )

        expect(%{new_state | pads: nil}) |> to(eq %{state() | pads: nil})
      end

      it "should add pad to the 'pads.data' list" do
        {{:ok, _info}, new_state} =
          described_module().handle_link(
            direction(),
            %{pad_ref: pad_ref(), pid: self(), pad_props: props()},
            %{pad_ref: other_ref(), pid: self()},
            other_info(),
            state()
          )

        expect(PadModel.assert_instance(new_state, pad_ref())) |> to(eq :ok)
      end
    end

    context "when pad is not present in the element" do
      let :pad_ref, do: :invalid_ref
      let :direction, do: :output
      let :other_ref, do: :other_input
      let :other_info, do: %{}
      let :props, do: %{}

      it "should raise an exception" do
        call = fn ->
          described_module().handle_link(
            direction(),
            %{pad_ref: pad_ref(), pid: self(), pad_props: props()},
            %{pad_ref: other_ref(), pid: self()},
            other_info(),
            state()
          )
        end

        expect(call) |> to(raise_exception(Membrane.LinkError))
      end
    end
  end

  describe "handle_unlink" do
    let :name, do: :element_name
    let :other_ref, do: :other_pad

    let :pad_data,
      do: %Membrane.Pad.Data{
        start_of_stream?: true,
        end_of_stream?: false
      }

    let! :state do
      {pad_info, state} =
        State.new(%{module: module(), name: name(), parent_clock: nil, sync: nil})
        |> Map.update!(:playback, &%{&1 | state: :playing})
        |> PadSpecHandler.init_pads()
        |> Bunch.Access.get_and_update_in(
          [:pads, :info],
          &{&1 |> Map.get(pad_name()), &1 |> Map.delete(pad_name())}
        )

      data = pad_data() |> Map.merge(pad_info)
      state |> Bunch.Access.update_in([:pads, :data], &(&1 |> Map.put(pad_ref(), data)))
    end

    before do
      allow module()
            |> to(accept(:handle_event, fn _, %EndOfStream{}, _, state -> {:ok, state} end))

      allow module() |> to(accept(:handle_pad_removed, fn _, _, state -> {:ok, state} end))
    end

    context "for element with static output pad" do
      let :module, do: TrivialFilter
      let :pad_name, do: :output
      let :pad_ref, do: pad_name()
      let :direction, do: :output

      it "should unlink that pad" do
        {result, _state} =
          described_module().handle_unlink(
            pad_ref(),
            state()
          )

        expect(result) |> to(eq :ok)
      end
    end

    context "for element with static input pad" do
      let :module, do: TrivialFilter
      let :pad_name, do: :input
      let :pad_ref, do: pad_name()
      let :direction, do: :input

      it "should unlink that pad and set end_of_stream" do
        expect(state().pads.data[pad_ref()]) |> not_to(eq nil)

        {result, state} =
          described_module().handle_unlink(
            pad_ref(),
            state()
          )

        expect(result) |> to(eq :ok)
        expect(module() |> to(accepted(:handle_end_of_stream)))
        expect(state.pads.data[pad_ref()]) |> to(be_nil())
      end
    end

    context "for element with dynamic input pad" do
      require Pad
      let :module, do: DynamicFilter
      let :pad_name, do: :input
      let :pad_ref, do: Pad.ref(:input, 0)

      let :pad_data,
        do: %Membrane.Pad.Data{
          start_of_stream?: true,
          end_of_stream?: false
        }

      let :direction, do: :input

      it "should unlink that pad, send end_of_stream and delete pad" do
        {result, state} =
          described_module().handle_unlink(
            pad_ref(),
            state()
          )

        expect(result) |> to(eq :ok)
        expect(module() |> to(accepted(:handle_end_of_stream)))
        expect(module() |> to(accepted(:handle_pad_removed)))
        expect(state.pads.data[pad_ref()]) |> to(be_nil())
      end
    end
  end
end
