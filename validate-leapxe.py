"""Compare the reconstructed Leap Xe model against a PyTorch reference on macOS."""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np


def test_input():
    n = np.arange(98_304) / 44_100
    l = 0.23 * np.sin(n * 2 * np.pi * 220) + 0.05 * np.cos(n * 2 * np.pi * 341)
    r = 0.21 * np.sin(n * 2 * np.pi * 220) + 0.06 * np.cos(n * 2 * np.pi * 487)
    samples = np.pad(np.stack([l, r]), ((0, 0), (1_024, 1_024)), mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(samples, 2048, axis=1)[:, ::512]
    frames = frames * np.hanning(2049)[:-1]
    z = np.fft.rfft(frames, axis=2).transpose(0, 2, 1)
    return np.stack([z[0].real, z[0].imag, z[1].real, z[1].imag])[None].astype(np.float32)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("package", "reference"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    model = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    output = model.predict({"mix": test_input()})["mask"]
    if output.shape != (1, 4, 1025, 193) or not np.isfinite(output).all():
        raise ValueError("Leap Xe returned invalid predictions.")
    reference = np.array(json.loads(args.reference.read_text()), dtype=np.float32)
    predicted = output.ravel()[::211]
    snr = 20 * np.log10(np.linalg.norm(reference) / max(np.linalg.norm(predicted - reference), 1e-12))
    print(f"Leap Xe Core ML mask fidelity: {snr:.1f} dB", flush=True)
    if snr < 25:
        raise ValueError("Leap Xe Core ML predictions differ from the author weights reference.")


if __name__ == "__main__":
    main()
