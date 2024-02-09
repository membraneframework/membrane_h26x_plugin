defmodule Membrane.H26x.NALuParser.Scheme do
  @moduledoc false
  # A module defining the behaviour which should be implemented
  # by each NALu scheme.

  # A NALu scheme is defining the internal structure of the NALu
  # and describes the fields which need to by fetched from the binary.
  # The `Membrane.H26x.NALuParser.Scheme` behaviour defines a
  # callback: `scheme/0`, which returns the description of NALu structure.
  # The syntax which can be used to describe the NALu scheme is designed to
  # match the syntax forms used in the H26x specification documents.
  # The scheme is read by the parser in an imperative manner, line by line.
  # The following statements are available:
  # * field: reads the appropriate number of bits, decodes the integer based on
  #   consumed bits and stores that integer under the given key in the parser's state map.
  # * if: introduces conditional parsing - if the condition is fulfilled, the
  #   binary will be parsed with the scheme which is nested inside the statement.
  # * for: allows to parse the scheme nested in the statement the desired number of times.
  # * calculate: allows to add to the parser's state map the desired value,
  #   under the given key.
  # * execute: allows to perform the custom actions with the payload and state, can be
  #   used to process the payload in a way which couldn't be acheived with the scheme syntax.
  # * save_as_global_state_t: saves the current parser state, concerning the NALu which is
  #   currently processed, in the map under the `:__global__` key in the state. Information
  #   from the saved state can be used while parsing the following NALus.
  #
  # Furthermore, `Scheme` behavior defines `defaults/0` callback,
  # which is used to provide the default values of the fields.
  alias Membrane.H26x.NALuParser.SchemeParser

  @type field :: {any(), SchemeParser.field()}
  @type if_clause :: {SchemeParser.value_provider(boolean()), t()}
  @type for_loop ::
          {[
             iterator: any(),
             from: SchemeParser.value_provider(integer()),
             to: SchemeParser.value_provider(integer())
           ], t()}
  @type calculate :: {any(), SchemeParser.value_provider(any())}
  @type execute :: (binary(), SchemeParser.t(), list(integer()) -> {binary(), SchemeParser.t()})
  @type save_as_global_state :: SchemeParser.value_provider(any())

  @type directive ::
          {:field, field()}
          | {:if, if_clause()}
          | {:for, for_loop()}
          | {:calculate, calculate()}
          | {:execute, execute()}
          | {:save_as_global_state, save_as_global_state()}
  @type t :: list(directive())

  @callback scheme() :: t()
  @callback defaults() :: keyword()
end
