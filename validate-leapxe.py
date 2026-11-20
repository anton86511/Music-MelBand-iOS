"""Compare Core ML's reconstructed vocal waveform with the original PyTorch model."""
import argparse
import sys
from pathlib import Path
from time import perf_counter

import coremltools as ct
import numpy as np
import soundfile as sf
import torch
import yaml
from scipy.signal import resample_poly


def test_audio(fixture):
    source, sample_rate = sf.read(fixture, dtype="float32")
    speech = resample_poly(source, 44_100, sample_rate)
    speech = speech[59_535:59_535 + 98_304] * 0.95
    if speech.shape != (98_304,):
        raise ValueError("Unexpected speech test fixture.")
    n = np.arange(speech.size) / 44_100
    return np.stack([
        speech + 0.025 * np.cos(n * 2 * np.pi * 341),
        speech + 0.031 * np.cos(n * 2 * np.pi * 487)
    ]).astype(np.float32)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("package", "checkpoint", "fixture", "reference_code"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.reference_code.resolve()))
    from models.bs_roformer.bs_roformer import BSRoformer

    torch.set_num_threads(4)
    with (args.reference_code / "config.yaml").open() as f:
        config = yaml.full_load(f)["model"]
    network = BSRoformer(**config).eval()
    network.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True), strict=True)
    audio = torch.from_numpy(test_audio(args.fixture))
    window = torch.hann_window(2048)
    with torch.inference_mode():
        reference = network(audio.unsqueeze(0)).reshape_as(audio).numpy()
        spectrum = torch.stft(audio, 2048, hop_length=512, window=window, return_complex=True)
    z = torch.view_as_real(spectrum)
    mix = z.permute(0, 3, 1, 2).reshape(1, 4, 1025, 193).numpy()
    model = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    output = model.predict({"mix": mix})["mask"]
    start = perf_counter()
    model.predict({"mix": mix})
    seconds = perf_counter() - start
    print(f"{args.package.stem} macOS Core ML warm prediction: {seconds:.2f} s per 2.23 s window", flush=True)
    if output.shape != (1, 4, 1025, 193) or not np.isfinite(output).all():
        raise ValueError("Leap Xe returned invalid predictions.")
    gain = output[0, ::2] + 1j * output[0, 1::2]
    stem = spectrum.numpy() * gain
    stem[:, 0, :] = 0
    predicted = torch.istft(torch.from_numpy(stem), 2048, hop_length=512, window=window, length=98_304).numpy()
    reference_level = np.linalg.norm(reference)
    if reference_level < 1.0:
        raise ValueError("Vocal verification fixture produced a nearly silent reference.")
    snr = 20 * np.log10(reference_level / max(np.linalg.norm(predicted - reference), 1e-12))
    print(f"Leap Xe Core ML vocal waveform fidelity: {snr:.1f} dB", flush=True)
    if snr < 30:
        raise ValueError("Leap Xe Core ML predictions differ from the author weights reference.")


if __name__ == "__main__":
    main()
