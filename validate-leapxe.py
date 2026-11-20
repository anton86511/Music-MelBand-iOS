"""Reconstruct the downloaded Leap Xe package and smoke-test Core ML on macOS."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

import coremltools as ct
import numpy as np


def restore(template: Path, checkpoint: Path, package: Path):
    plan = json.loads((template / "plan.json").read_text())
    raw_hash = "b739c1d2d87a81cd3dd3844ed9ad0bd678708c7a0a761a03a1aaff9af79a096d"
    with checkpoint.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != raw_hash:
            raise ValueError("Unexpected author checkpoint revision.")
    shutil.rmtree(package, ignore_errors=True)
    core = package / "Data/com.apple.CoreML"
    (core / "weights").mkdir(parents=True)
    shutil.copyfile(template / "Manifest.json", package / "Manifest.json")
    spec = core / "model.mlmodel"
    weights = core / "weights/weight.bin"
    shutil.copyfile(template / "model.template", spec)
    with (checkpoint.open("rb") as source, (template / "literals.bin").open("rb") as literal,
          spec.open("r+b") as model, weights.open("w+b") as weight_file):
        weight_file.truncate(plan["weightsSize"])
        for p in plan["patches"]:
            stream = literal if p["kind"] == "literal" else source
            out = model if p["target"] == 0 else weight_file
            stream.seek(p["source"])
            data = stream.read(p["count"] * (1 if p["kind"] == "literal" else 4))
            if p["kind"] == "f16":
                data = np.frombuffer(data, dtype="<f4").astype("<f2").tobytes()
            out.seek(p["offset"])
            out.write(data)
    for name, key in ((spec, "modelSHA"), (weights, "weightsSHA")):
        with name.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != plan[key]:
                raise ValueError(f"Reconstructed {key} failed validation.")


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
    for argument in ("template", "checkpoint", "package", "reference"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    restore(args.template, args.checkpoint, args.package)
    print("Leap Xe checkpoint hydration passed both SHA-256 checks.", flush=True)
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
