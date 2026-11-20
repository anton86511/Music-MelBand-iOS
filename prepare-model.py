"""Adapt the original static ONNX graph to a shorter time window without changing weights."""
import argparse
import hashlib
from pathlib import Path

import numpy as np
import onnx
from onnx import AttributeProto, numpy_helper

SOURCE_HASH = "e9570dac2ae14382c99357a547a6739777a029ad7f2b5f6e6bc22e9b0e7b2580"
SOURCE_FRAMES = 801


def prepare(source: Path, destination: Path, frames: int) -> None:
    with source.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != SOURCE_HASH:
            raise ValueError("Unexpected upstream checkpoint")
    if not 101 <= frames < SOURCE_FRAMES:
        raise ValueError("Invalid frame count")
    model = onnx.load(source)
    graph = model.graph
    for value in (*graph.input, *graph.output, *graph.value_info):
        for dimension in value.type.tensor_type.shape.dim:
            if dimension.dim_value == SOURCE_FRAMES:
                dimension.dim_value = frames
    for node in graph.node:
        if node.op_type != "Constant":
            continue
        for attribute in node.attribute:
            if attribute.type != AttributeProto.TENSOR:
                continue
            tensor = attribute.t
            data = numpy_helper.to_array(tensor)
            if SOURCE_FRAMES in data.shape:
                slices = tuple(slice(0, frames) if size == SOURCE_FRAMES else slice(None) for size in data.shape)
                data = data[slices]
            elif data.ndim == 1 and data.dtype == np.int64 and SOURCE_FRAMES in data:
                data = np.where(data == SOURCE_FRAMES, frames, data)
            else:
                continue
            tensor.CopyFrom(numpy_helper.from_array(data, name=tensor.name))
    onnx.checker.check_model(model)
    destination.write_bytes(model.SerializeToString(deterministic=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--frames", type=int, default=201)
    args = parser.parse_args()
    prepare(args.source, args.destination, args.frames)
