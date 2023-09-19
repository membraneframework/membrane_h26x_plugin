Mix.install([
  {:membrane_file_plugin, "~> 0.14.0"},
  {:membrane_h264_plugin, path: "/Users/jakubpryc/Membrane/membrane_h264_plugin"},
  {:membrane_stream_plugin, "~> 0.3.1"}
])

defmodule Aa do
  alias Membrane.RCPipeline

  import Membrane.ChildrenSpec

  def run() do
    spss = [<<103, 66, 0, 41, 226, 144, 25, 7, 127, 17, 128, 183, 1, 1, 1, 225, 226, 68, 84>>]
    ppss = [<<104, 206, 60, 128>>]

    pipeline = RCPipeline.start_link!()

    RCPipeline.exec_actions(pipeline,
      spec:
        child(:source, %Membrane.File.Source{location: "stream.dump"})
        |> child(:deserializer, Membrane.Stream.Deserializer)
        |> child(:parser, %Membrane.H264.Parser{
          spss: spss,
          ppss: ppss,
          output_alignment: :nalu,
          output_stream_structure: :annexb,
          skip_until_keyframe: true,
          repeat_parameter_sets: true
        })
        |> child(:serializer, Membrane.Stream.Serializer)
        |> child(:sink, %Membrane.File.Sink{location: "aaa.msr"})
    )

    ref = Process.monitor(pipeline)

    receive do
      {:DOWN, ^ref, :process, _pipeline_pid, _reason} ->
        :ok
    end
  end
end

Aa.run()
