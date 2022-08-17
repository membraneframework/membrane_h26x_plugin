defmodule Membrane.H264.Parser.NALuPayload do
  alias Membrane.H264.Common
  @moduledoc false

  @nalu_types %{
                0 => :unspecified,
                1 => :non_idr,
                2 => :part_a,
                3 => :part_b,
                4 => :part_c,
                5 => :idr,
                6 => :sei,
                7 => :sps,
                8 => :pps,
                9 => :aud,
                10 => :end_of_seq,
                11 => :end_of_stream,
                12 => :filler_data,
                13 => :sps_extension,
                14 => :prefix_nal_unit,
                15 => :subset_sps,
                (16..18) => :reserved,
                19 => :auxiliary_non_part,
                20 => :extension,
                (21..23) => :reserved,
                (24..31) => :unspecified
              }
              |> Enum.flat_map(fn
                {k, v} when is_integer(k) -> [{k, v}]
                {k, v} -> Enum.map(k, &{&1, v})
              end)
              |> Map.new()

  def nalu_types, do: @nalu_types

  def parse_with_scheme(payload, scheme, state \\ %{__global__: %{}}, field_prefix \\ "") do
    scheme
    |> Enum.reduce({payload, state}, fn {operator, arguments}, {payload, state} ->
      case operator do
        :field ->
          {name, type} = arguments
          {field_value, payload} = parse_field(payload, state, type)
          full_name = (Atom.to_string(name) <> field_prefix) |> String.to_atom()
          {payload, Map.put(state, full_name, field_value)}

        :if ->
          {condition, scheme} = arguments
          {condition_function, args_list} = make_function(condition)

          if apply(condition_function, get_args(args_list, state)),
            do: parse_with_scheme(payload, scheme, state),
            else: {payload, state}

        :for ->
          {[iterator: iterator_name, from: min_value, to: max_value], scheme} = arguments
          {min_value, min_args_list} = make_function(min_value)
          {max_value, max_args_list} = make_function(max_value)

          {payload, state} =
            Enum.reduce(
              apply(min_value, get_args(min_args_list, state))..apply(
                max_value,
                get_args(max_args_list, state)
              ),
              {payload, state},
              fn iterator, {payload, state} ->
                state = Map.put(state, iterator_name, iterator)

                parse_with_scheme(
                  payload,
                  scheme,
                  state,
                  field_prefix <> "_" <> Integer.to_string(iterator)
                )
              end
            )

          state = Map.delete(state, iterator_name)
          {payload, state}

        :calculate ->
          {name, to_calculate} = arguments
          {function, args_list} = make_function(to_calculate)
          {payload, Map.put(state, name, apply(function, get_args(args_list, state)))}

        :execute ->
          function = arguments
          function.(payload, state, field_prefix)

        :save_state_as_global_state ->
          key_generator = arguments
          {key_generating_function, args_list} = make_function(key_generator)
          key = apply(key_generating_function, get_args(args_list, state))

          state_without_global =
            state |> Enum.filter(fn {key, _value} -> key != :__global__ end) |> Map.new()

          {payload,
           Map.put(state, :__global__, Map.put(state.__global__, key, state_without_global))}
      end
    end)
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
      :u1 ->
        <<value::unsigned-size(1), rest::bitstring>> = payload
        {value, rest}

      :u2 ->
        <<value::unsigned-size(2), rest::bitstring>> = payload
        {value, rest}

      :u3 ->
        <<value::unsigned-size(3), rest::bitstring>> = payload
        {value, rest}

      :u4 ->
        <<value::unsigned-size(4), rest::bitstring>> = payload
        {value, rest}

      :u5 ->
        <<value::unsigned-size(5), rest::bitstring>> = payload
        {value, rest}

      :u8 ->
        <<value::unsigned-size(8), rest::bitstring>> = payload
        {value, rest}

      :u16 ->
        <<value::unsigned-size(16), rest::bitstring>> = payload
        {value, rest}

      :u32 ->
        <<value::unsigned-size(32), rest::bitstring>> = payload
        {value, rest}

      {:uv, lambda, args} ->
        size = apply(lambda, get_args(args, state))
        <<value::unsigned-size(size), rest::bitstring>> = payload
        {value, rest}

      :ue ->
        Common.to_integer(payload)

      :se ->
        Common.to_integer(payload, negatives: true)
    end
  end

  defp make_function({function, args}) when is_function(function), do: {function, args}
  defp make_function(value), do: {fn -> value end, []}
end
