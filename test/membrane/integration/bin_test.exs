defmodule Membrane.Core.BinTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.Support.Bin.TestBins
  alias Membrane.Support.Bin.TestBins.{TestDynamicPadFilter, TestFilter}
  alias Membrane.Core.Bin
  alias Membrane.Core.Message
  alias Membrane.Testing

  require Membrane.Core.Message

  describe "Starting and transmitting buffers" do
    test "in simple, flat use case" do
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: %Testing.Source{output: buffers},
            test_bin: %TestBins.SimpleBin{
              filter1: TestFilter,
              filter2: TestFilter
            },
            sink: Testing.Sink
          ]
        })

      assert_data_flows_through(pipeline, buffers)
    end

    test "when bin is next to a bin" do
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: %Testing.Source{output: buffers},
            test_bin1: %TestBins.SimpleBin{
              filter1: TestFilter,
              filter2: TestFilter
            },
            test_bin2: %TestBins.SimpleBin{
              filter1: TestFilter,
              filter2: TestFilter
            },
            sink: Testing.Sink
          ]
        })

      assert_data_flows_through(pipeline, buffers)
    end

    test "when bins are nested" do
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: %Testing.Source{output: buffers},
            test_bin: %TestBins.SimpleBin{
              filter1: TestFilter,
              filter2: %TestBins.SimpleBin{
                filter1: TestFilter,
                filter2: TestFilter
              }
            },
            sink: Testing.Sink
          ]
        })

      assert_data_flows_through(pipeline, buffers)
    end

    test "when there are consecutive bins that are nested" do
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: %Testing.Source{output: buffers},
            test_bin: %TestBins.SimpleBin{
              filter1: %TestBins.SimpleBin{
                filter1: TestFilter,
                filter2: TestFilter
              },
              filter2: %TestBins.SimpleBin{
                filter1: TestFilter,
                filter2: TestFilter
              }
            },
            sink: Testing.Sink
          ]
        })

      assert_data_flows_through(pipeline, buffers)
    end

    test "when pipeline has only one element being a padless bin" do
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            test_bin: %TestBins.TestPadlessBin{
              source: %Testing.Source{output: buffers},
              sink: Testing.Sink
            }
          ]
        })

      assert_playing(pipeline)

      assert_pipeline_notified(pipeline, :test_bin, {:handle_element_start_of_stream, {:sink, _}})

      assert_buffers_flow_through(pipeline, buffers, :test_bin)

      assert_pipeline_notified(pipeline, :test_bin, {:handle_element_end_of_stream, {:sink, _}})
    end

    test "when bin is a sink bin" do
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: %Testing.Source{output: buffers},
            test_bin: %TestBins.TestSinkBin{
              filter: TestFilter,
              sink: Testing.Sink
            }
          ]
        })

      assert_playing(pipeline)

      assert_pipeline_notified(
        pipeline,
        :test_bin,
        {:handle_element_start_of_stream, {:filter, _}}
      )

      assert_pipeline_notified(pipeline, :test_bin, {:handle_element_start_of_stream, {:sink, _}})

      assert_buffers_flow_through(pipeline, buffers, :test_bin)

      assert_pipeline_notified(pipeline, :test_bin, {:handle_element_end_of_stream, {:filter, _}})
      assert_pipeline_notified(pipeline, :test_bin, {:handle_element_end_of_stream, {:sink, _}})
    end
  end

  describe "Handling DOWN messages" do
    test "should shutdown when parent is down" do
      pipeline_mock = spawn(fn -> receive do: (:exit -> :ok) end)

      {:ok, bin_pid} =
        pipeline_mock
        |> bin_init_options
        |> Bin.start()

      ref = Process.monitor(bin_pid)
      send(pipeline_mock, :exit)
      assert_receive {:DOWN, ^ref, :process, ^bin_pid, {:shutdown, :parent_crash}}
    end

    test "DOWN message should be delivered to handle_other if it's not coming from parent" do
      {:ok, bin_pid} =
        self()
        |> bin_init_options
        |> Bin.start()

      monitored_proc = spawn(fn -> receive do: (:exit -> :ok) end)
      on_exit(fn -> send(monitored_proc, :exit) end)
      ref = Process.monitor(monitored_proc)

      send(bin_pid, {:DOWN, ref, :process, monitored_proc, :normal})

      assert_receive Message.new(:notification, [
                       :name,
                       {:DOWN, ^ref, :process, ^monitored_proc, :normal}
                     ])

      assert Process.alive?(bin_pid)
    end
  end

  describe "Events passing in pipeline" do
    test "notifications are handled by bin as if it's a pipeline" do
      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: Testing.Source,
            test_bin: %TestBins.SimpleBin{
              filter1: TestFilter,
              filter2: TestFilter
            },
            sink: %Testing.Sink{autodemand: false}
          ]
        })

      :ok = Testing.Pipeline.play(pipeline)

      assert_pipeline_playback_changed(pipeline, :stopped, :prepared)
      assert_pipeline_playback_changed(pipeline, :prepared, :playing)

      {:ok, filter1_pid} = get_child_pid(pipeline, [:test_bin, :filter1])

      send(filter1_pid, {:notify_parent, :some_example_notification})

      # As this test's implementation of bin only passes notifications up
      assert_pipeline_notified(pipeline, :test_bin, :some_example_notification)
    end
  end

  describe "Dynamic pads" do
    test "handle_pad_added is called only for public pads" do
      alias Membrane.Pad
      require Pad
      buffers = ['a', 'b', 'c']

      {:ok, pipeline} =
        Testing.Pipeline.start_link(%Testing.Pipeline.Options{
          elements: [
            source: %Testing.Source{output: buffers},
            test_bin: %TestBins.TestDynamicPadBin{
              filter1: TestDynamicPadFilter,
              filter2: TestDynamicPadFilter
            },
            sink: Testing.Sink
          ]
        })

      assert_data_flows_through(pipeline, buffers)
      assert_pipeline_notified(pipeline, :test_bin, {:handle_pad_added, Pad.ref(:input, _)})
      assert_pipeline_notified(pipeline, :test_bin, {:handle_pad_added, Pad.ref(:output, _)})

      refute_pipeline_notified(pipeline, :test_bin, {:handle_pad_added, _})
    end
  end

  describe "Integration with clocks" do
    defmodule ClockElement do
      use Membrane.Source

      def_output_pad :output, caps: :any

      def_clock()
    end

    defmodule ClockBin do
      use Membrane.Bin

      def_clock()

      @impl true
      def handle_init(_options) do
        children = [element_child: ClockElement]

        spec = %Membrane.ParentSpec{
          children: children,
          links: [],
          clock_provider: :element_child
        }

        {{:ok, spec: spec}, :ignored}
      end
    end

    defmodule ClockPipeline do
      use Membrane.Pipeline

      @impl true
      def handle_init(_options) do
        children = [bin_child: ClockBin]

        {{:ok,
          spec: %Membrane.ParentSpec{children: children, links: [], clock_provider: :bin_child}},
         :ignored}
      end
    end

    test "Bin is clock_provider" do
      {:ok, pid} = ClockPipeline.start_link()

      %Membrane.Core.Pipeline.State{synchronization: %{clock_provider: pipeline_clock_provider}} =
        state = :sys.get_state(pid)

      assert %{choice: :manual, clock: clock1, provider: :bin_child} = pipeline_clock_provider
      refute is_nil(clock1)

      %{pid: bin_pid} = state.children[:bin_child]

      %Membrane.Core.Bin.State{synchronization: %{clock_provider: bin_clock_provider}} =
        :sys.get_state(bin_pid)

      assert %{choice: :manual, clock: clock2, provider: :element_child} = bin_clock_provider
      refute is_nil(clock2)

      assert proxy_for?(clock1, clock2)
    end

    defp proxy_for?(c1, c2) do
      c1_state = :sys.get_state(c1)
      assert c1_state.proxy_for == c2
    end
  end

  defp get_child_pid(last_child_pid, []) when is_pid(last_child_pid) do
    {:ok, last_child_pid}
  end

  defp get_child_pid(last_child_pid, [child | children]) when is_pid(last_child_pid) do
    state = :sys.get_state(last_child_pid)
    %{pid: child_pid} = state.children[child]
    get_child_pid(child_pid, children)
  end

  defp get_child_pid(_last_child_pid, _children) do
    {:error, :child_was_not_found}
  end

  defp assert_data_flows_through(pipeline, buffers, receiving_element \\ :sink) do
    assert_playing(pipeline)

    assert_start_of_stream(pipeline, ^receiving_element)

    assert_buffers_flow_through(pipeline, buffers, receiving_element)

    assert_end_of_stream(pipeline, ^receiving_element)
  end

  defp assert_buffers_flow_through(pipeline, buffers, receiving_element) do
    buffers
    |> Enum.each(fn b ->
      assert_sink_buffer(pipeline, receiving_element, %Membrane.Buffer{payload: ^b})
    end)
  end

  defp assert_playing(pipeline) do
    :ok = Testing.Pipeline.play(pipeline)

    assert_pipeline_playback_changed(pipeline, :stopped, :prepared)
    assert_pipeline_playback_changed(pipeline, :prepared, :playing)
  end

  defp bin_init_options(pipeline) do
    %{
      name: :name,
      module: TestBins.SimpleBin,
      parent: pipeline,
      parent_clock: nil,
      log_metadata: [],
      user_options: %{
        filter1: TestFilter,
        filter2: TestFilter
      }
    }
  end
end
