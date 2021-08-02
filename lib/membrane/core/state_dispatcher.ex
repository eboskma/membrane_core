defmodule Membrane.Core.StateDispatcher do
  @moduledoc false

  @type group_t :: :parent | :child | :any

  @type component_t :: :bin | :element | :pipeline

  @type kind_t ::
          Membrane.Core.Bin.State
          | Membrane.Core.Element.State
          | Membrane.Core.Pipeline.State

  @type state_t ::
          Membrane.Core.Bin.State.t()
          | Membrane.Core.Element.State.t()
          | Membrane.Core.Pipeline.State.t()

  @components [:bin, :element, :pipeline]
  @groups [:parent, :child, :any]

  @membership %{
    parent: [:bin, :pipeline],
    child: [:bin, :element],
    any: @components
  }

  require Record

  @spec restrict(group_t() | component_t()) :: [component_t()]
  def restrict(spec) when spec in @groups, do: @membership[spec]
  def restrict(spec) when spec in @components, do: [spec]

  def kind_of(state) when Record.is_record(state), do: elem(state, 0)

  def kind_of(component) when is_atom(component),
    do:
      Module.concat([
        Membrane.Core,
        component |> Atom.to_string() |> String.capitalize(),
        State
      ])

  defguard bin?(state) when Record.is_record(state, Membrane.Core.Bin.State)
  defguard element?(state) when Record.is_record(state, Membrane.Core.Element.State)
  defguard pipeline?(state) when Record.is_record(state, Membrane.Core.Pipeline.State)

  # FIXME: inconsistent State initialisation
  defmacro element(map) when is_map(map) do
    kind = kind_of(:element)
    quote do
      require unquote(kind)
      apply(unquote(kind), :new, unquote(map))
    end
  end

  @components
  |> Enum.map(fn component ->
    defmacro unquote(component)(kw) do
      kind = kind_of(unquote(component))
      quote do
        require unquote(kind)
        apply(unquote(kind), :state, unquote(kw))
      end
    end

    defmacro unquote(component)(state, kw) do
      kind = kind_of(unquote(component))
      quote do
        require unquote(kind)
        apply(unquote(kind), :state, [unquote(state) | unquote(kw)])
      end
    end
  end)

  (@components ++ @groups)
  |> Enum.map(fn spec ->
    defmacro unquote(:"get_#{spec}")(state, key), do: spec_op(unquote(spec), [state, key])
    defmacro unquote(:"update_#{spec}")(state, kw), do: spec_op(unquote(spec), [state | kw])
  end)

  defp spec_op(spec, args) when spec in @components do
    quote do
      apply(unquote(__MODULE__), unquote(spec), unquote(args))
    end
  end

  defp spec_op(spec, [state | _] = args) when spec in @groups do
    clauses =
      spec
      |> restrict()
      |> Enum.flat_map(fn component ->
        quote do
          unquote(kind_of(component)) ->
            apply(unquote(__MODULE__), unquote(component), unquote(args))
        end
      end)

    quote do
      case unquote(__MODULE__).kind_of(unquote(state)) do
        unquote(clauses)
      end
    end
  end
end