"""Convert the pinned UVR Inst HQ 4 ONNX model to the app's Core ML contract."""

import argparse
import platform
from pathlib import Path

import coremltools as ct
import numpy as np
import onnxruntime as ort
import torch
from onnx2torch import convert

SHAPE = (1, 4, 2560, 256)
FLOAT16 = 65552


def verify(output, reference, minimum_snr):
    if output.shape != SHAPE or not np.isfinite(output).all():
        raise ValueError("The converted model produced invalid output.")
    snr = 20 * np.log10(np.linalg.norm(reference) / max(np.linalg.norm(output - reference), 1e-12))
    if snr < minimum_snr:
        raise ValueError(f"Conversion fidelity {snr:.1f} dB is below {minimum_snr} dB.")
    print(f"Verified against ONNX: {snr:.1f} dB SNR", flush=True)


def main(source: Path, destination: Path):
    torch.set_num_threads(2)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    session = ort.InferenceSession(str(source), options, providers=["CPUExecutionProvider"])
    audio_spectrum = np.random.default_rng(20).normal(0, 3, SHAPE).astype(np.float32)
    reference = session.run(["output"], {"input": audio_spectrum})[0]
    example = torch.from_numpy(audio_spectrum)
    network = convert(str(source)).eval()
    with torch.inference_mode():
        verify(network(example).numpy(), reference, 75)
    with torch.no_grad():
        traced = torch.jit.trace(network, example)
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=SHAPE, dtype=np.float16)],
        outputs=[ct.TensorType(name="output", dtype=np.float16)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.iOS16,
        skip_model_load=True,
    )
    model.save(str(destination))
    spec = ct.models.MLModel(str(destination), skip_model_load=True).get_spec()
    inputs = spec.description.input
    outputs = spec.description.output
    if (spec.WhichOneof("Type") != "mlProgram" or len(inputs) != 1 or len(outputs) != 1
            or inputs[0].name != "input" or outputs[0].name != "output"
            or tuple(inputs[0].type.multiArrayType.shape) != SHAPE
            or inputs[0].type.multiArrayType.dataType != FLOAT16
            or outputs[0].type.multiArrayType.dataType != FLOAT16):
        raise ValueError("Unexpected Core ML model signature.")
    if platform.system() == "Darwin":
        loaded = ct.models.MLModel(str(destination), compute_units=ct.ComputeUnit.CPU_ONLY)
        verify(loaded.predict({"input": audio_spectrum.astype(np.float16)})["output"].astype(np.float32),
               reference, 40)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    main(args.source, args.destination)
