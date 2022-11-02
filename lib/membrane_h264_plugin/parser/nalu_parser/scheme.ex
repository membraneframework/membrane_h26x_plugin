defmodule Membrane.H264.Parser.NALuParser.Scheme do
  @moduledoc false
  # A module defining the behaviour which should be implemented
  # by each NALu scheme.

  # A NALu scheme is defining the internal structure of the NALu
  # and describes the fields which need to by fetched from the binary.
  # The `Membrane.H264.Parser.SchemeParserScheme` behaviour defines a single
  # callback: `scheme/0`, which returns the description of NALu structure.
  # The syntax which can be used to describe the NALu scheme is designed to
  # match the syntax forms used in *7.1.* chapter of the *"ITU-T Rec. H.264 (01/2012)"*.
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

  alias Membrane.H264.Parser.NALuParser.SchemeParser

  @type field_t :: {any(), SchemeParser.field_t()}
  @type if_t :: {value_provider_t(boolean()), t()}
  @type for_t ::
          {[iterator: any(), from: value_provider_t(integer()), to: value_provider_t(integer())],
           t()}
  @type calculate_t :: {any(), value_provider_t(any())}
  @type execute_t :: (binary(), SchemeParser.t(), list(integer()) -> {binary(), SchemeParser.t()})
  @type save_as_global_state_t :: value_provider_t(any())

  @typedoc """
  This type defines a value provider which provides values used in further
  processing of a parser.

  A value provider can be either a hardcoded value, known at the compilation
  time, or a tuple consisting of a lambda expression and the list of keys
  mapping to some values in the parser's state. If the value provider is a tuple,
  then it's first element - the lambda expression-  is invoked with the arguments
  being the values of the fields which are available in the parser's state under
  the key names given in the parser's state, and the value used in the further
  processing is the value returned by that lambda expression.
  """
  @type value_provider_t(return_type) :: return_type | {(... -> return_type), list(any())}

  @type directive_t ::
          {:field, field_t()}
          | {:if, if_t()}
          | {:for, for_t()}
          | {:calculate, calculate_t()}
          | {:execute, execute_t()}
          | {:save_as_global_state, save_as_global_state_t()}
  @type t :: list(directive_t())

  @callback scheme() :: t()
end
