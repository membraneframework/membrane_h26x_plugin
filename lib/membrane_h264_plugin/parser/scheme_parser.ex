defmodule Membrane.H264.Parser.SchemeParser do
  @moduledoc """
  The module providing functions to parse the binary based on the given Scheme
  """
  alias Membrane.H264.Common
  alias Membrane.H264.Parser.SchemeParser.Scheme
  alias Membrane.H264.Parser.SchemeParser.State

  @typedoc """
  A type describing the field types which can be used in NALu scheme definition.
  Defined as in: 7.2 Specification of syntax functions, categories, and descriptors of the "ITU-T Rec. H.264 (01/2012)"
  """
  @type field_t ::
          :u1
          | :u2
          | :u3
          | :u4
          | :u5
          | :u8
          | :u16
          | :u16
          | {:uv, Scheme.value_provider_t(integer())}
          | :ue
          | :se

  @doc """
  Parses the binary stream representing a NALu, based on the scheme definition. Returns the remaining bitstring and the stated updated with the information fetched from the NALu.
  """
  @spec parse_with_scheme(binary(), Scheme.t(), State.t(), list(integer())) ::
          {bitstring(), State.t()}
  def parse_with_scheme(
        payload,
        scheme,
        state \\ %State{__local__: %{}, __global__: %{}},
        iterators \\ []
      ) do
    scheme
    |> Enum.reduce({payload, state}, fn {operator, arguments}, {payload, state} ->
      case operator do
        :field ->
          {name, type} = arguments
          {field_value, payload} = parse_field(payload, state, type)

          {payload,
           insert_into_parser_state(state, field_value, [:__local__] ++ [name] ++ iterators)}

        :if ->
          {condition, scheme} = arguments
          run_conditionally(payload, state, scheme, condition)

        :for ->
          {[iterator: iterator_name, from: min_value, to: max_value], scheme} = arguments
          loop(payload, state, scheme, iterators, iterator_name, min_value, max_value)

        :calculate ->
          {name, to_calculate} = arguments
          {function, args_list} = make_function(to_calculate)

          {payload,
           Bunch.Access.put_in(
             state,
             [:__local__, name],
             apply(function, get_args(args_list, state.__local__))
           )}

        :execute ->
          function = arguments
          function.(payload, state, iterators)

        :save_state_as_global_state ->
          key_generator = arguments
          {key_generating_function, args_list} = make_function(key_generator)
          key = apply(key_generating_function, get_args(args_list, state.__local__))

          {payload, Bunch.Access.put_in(state, [:__global__, key], state.__local__)}
      end
    end)
  end

  defp run_conditionally(payload, state, scheme, condition) do
    {condition_function, args_list} = make_function(condition)

    if apply(condition_function, get_args(args_list, state.__local__)),
      do: parse_with_scheme(payload, scheme, state),
      else: {payload, state}
  end

  defp loop(payload, state, scheme, previous_iterators, iterator_name, min_value, max_value) do
    {min_value, min_args_list} = make_function(min_value)
    {max_value, max_args_list} = make_function(max_value)

    {payload, state} =
      Enum.reduce(
        apply(min_value, get_args(min_args_list, state.__local__))..apply(
          max_value,
          get_args(max_args_list, state.__local__)
        ),
        {payload, state},
        fn iterator, {payload, state} ->
          state = Bunch.Access.put_in(state, [:__local__, iterator_name], iterator)

          parse_with_scheme(
            payload,
            scheme,
            state,
            previous_iterators ++ [iterator]
          )
        end
      )

    state = Bunch.Access.delete_in(state, [:__local__, iterator_name])
    {payload, state}
  end

  defp get_args(args_names, state) do
    Enum.map(args_names, fn arg_name ->
      lexems = Regex.scan(~r"\@.*?\@", Atom.to_string(arg_name))

      variables =
        lexems
        |> Enum.map(fn lexem ->
          variable_name = String.slice(lexem, 1..-2)
          Map.get(state, variable_name) |> Integer.to_string()
        end)

      arg_name = Atom.to_string(arg_name)

      full_arg_name =
        Enum.zip(lexems, variables)
        |> Enum.reduce(arg_name, fn {lexem, variable}, arg_name ->
          String.replace(arg_name, lexem, variable)
        end)
        |> String.to_atom()

      Map.fetch!(state, full_arg_name)
    end)
  end

  defp parse_field(payload, state, type) do
    case type do
      {:uv, lambda, args} ->
        size = apply(lambda, get_args(args, state.__local__))
        <<value::unsigned-size(size), rest::bitstring>> = payload
        {value, rest}

      :ue ->
        Common.ExpGolombConverter.to_integer(payload)

      :se ->
        Common.ExpGolombConverter.to_integer(payload, negatives: true)

      unsigned_int ->
        how_many_bits = Atom.to_string(unsigned_int) |> String.slice(1..-1) |> String.to_integer()
        <<value::unsigned-size(how_many_bits), rest::bitstring>> = payload
        {value, rest}
    end
  end

  defp make_function({function, args}) when is_function(function), do: {function, args}
  defp make_function(value), do: {fn -> value end, []}

  defp insert_into_parser_state(state, value, iterators_list, already_consumed_iterators \\ [])

  defp insert_into_parser_state(state, value, [], already_consumed_iterators) do
    Bunch.Access.put_in(state, already_consumed_iterators, value)
  end

  defp insert_into_parser_state(state, value, iterators_list, already_consumed_iterators) do
    [first | rest] = iterators_list
    to_insert = Bunch.Access.get_in(state, already_consumed_iterators ++ [first])
    to_insert = if to_insert == nil, do: %{}, else: to_insert
    state = Bunch.Access.put_in(state, already_consumed_iterators ++ [first], to_insert)
    insert_into_parser_state(state, value, rest, already_consumed_iterators ++ [first])
  end
end
