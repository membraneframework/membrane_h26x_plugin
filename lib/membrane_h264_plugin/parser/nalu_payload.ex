defmodule Membrane.H264.Parser.NALuPayload do
  alias Membrane.H264.Common
  @moduledoc false
  def parse_scheme(payload, scheme, state \\ %{}, field_prefix \\ "") do
    scheme |> Enum.reduce({state, payload}, fn {operator, arguments}, {state, payload} ->
      case operator do
        :field -> {name, type} = arguments
          {field_value, payload} = parse_field(payload, type)
          full_name = Atom.to_string(name)<>field_prefix |> String.to_atom()
          {Map.put(state, full_name, field_value), payload}
        :if -> {{condition, args_list}, scheme} = arguments
          if apply(condition,  get_args(args_list, state)), do: parse_scheme(payload, scheme, state), else: {state, payload}
        :for -> {{iterator_name, max_value, args_list}, scheme} = arguments

          {state, payload} = Enum.reduce(1..apply(max_value,  get_args(args_list, state)), {state, payload}, fn iterator, {state, payload} ->
            state = Map.put(state, iterator_name, iterator)
            parse_scheme(payload, scheme, state, field_prefix<>"_"<>Integer.to_string(iterator) )
          end)
          state = Map.delete(state, iterator_name)
          {state, payload}
        :calculate -> {name, function, args_list} = arguments
          {Map.put(state, name, apply(function, get_args(args_list, state))), payload}
        :execute -> fun = arguments
          fun.(state, payload, field_prefix)
      end
    end)
  end

  defp get_args(args_names, state) do
    Enum.map(args_names, fn arg_name ->
      lexems = Regex.scan(~r"\@.*?\@", Atom.to_string(arg_name) )
      variables = lexems |> Enum.map(fn lexem ->
        variable_name = String.slice(lexem, 1..-2)
        Map.get(state, variable_name) |> Integer.to_string()
      end)
      arg_name = Atom.to_string(arg_name)
      full_arg_name = Enum.zip(lexems, variables) |> Enum.reduce(arg_name, fn {lexem, variable}, arg_name -> String.replace(arg_name, lexem, variable) end) |> String.to_atom()
      Map.fetch!(state, full_arg_name)
    end)
  end

  defp parse_field(payload, type) do
    case type do
      :u1 -> <<value::unsigned-size(1), rest::bitstring>> = payload
        {value, rest}
      :u2 -> <<value::unsigned-size(2), rest::bitstring>> = payload
        {value, rest}
      :u3 -> <<value::unsigned-size(3), rest::bitstring>> = payload
        {value, rest}
      :u4 -> <<value::unsigned-size(4), rest::bitstring>> = payload
        {value, rest}
      :u5 -> <<value::unsigned-size(5), rest::bitstring>> = payload
        {value, rest}
      :u8 -> <<value::unsigned-size(8), rest::bitstring>> = payload
        {value, rest}
      :u16 ->  <<value::unsigned-size(16), rest::bitstring>> = payload
        {value, rest}
      :u32 ->  <<value::unsigned-size(32), rest::bitstring>> = payload
        {value, rest}
      :ue -> Common.to_integer(payload)
      :se -> Common.to_integer(payload, negatives: true)
    end
  end
end
