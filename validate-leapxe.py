"""Compare the reconstructed Leap Xe model against a PyTorch reference on macOS."""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np


def test_input():
    n = np.arange(98_304) / 44_100
    phase = 2 * np.pi * (175 * n + 0.28 * np.sin(2 * np.pi * 5 * n))
    voice = np.zeros_like(n)
    for harmonic in range(1, 31):
        frequency = harmonic * 175
        formants = sum(np.exp(-((frequency - center) / width)**2)
                       for center, width in ((750, 105), (1250, 145), (2450, 240)))
        voice += (0.014 + 0.04 * formants) * np.sin(harmonic * phase)
    voice *= (0.5 + 0.5 * np.sin(2 * np.pi * 1.4 * n)) ** 2
    l = voice + 0.05 * np.cos(n * 2 * np.pi * 341)
    r = voice + 0.06 * np.cos(n * 2 * np.pi * 487)
    samples = np.pad(np.stack([l, r]), ((0, 0), (1_024, 1_024)), mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(samples, 2048, axis=1)[:, ::512]
    frames = frames * np.hanning(2049)[:-1]
    z = np.fft.rfft(frames, axis=2).transpose(0, 2, 1)
    return np.stack([z[0].real, z[0].imag, z[1].real, z[1].imag])[None].astype(np.float32)


def waveform(mix, mask):
    spectrum = mix[0, ::2] + 1j * mix[0, 1::2]
    gain = mask[0, ::2] + 1j * mask[0, 1::2]
    stem = spectrum * gain
    stem[:, 0, :] = 0
    window = np.hanning(2049)[:-1]
    blocks = np.fft.irfft(stem.transpose(0, 2, 1), axis=2) * window
    signal = np.zeros((2, 98_304 + 2_048))
    normalization = np.zeros(signal.shape[-1])
    for i in range(193):
        span = slice(i * 512, i * 512 + 2048)
        signal[:, span] += blocks[:, i, :]
        normalization[span] += window * window
    center = slice(1024, -1024)
    return (signal[:, center] / normalization[center]).astype(np.float32)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("package", "reference"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    model = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    mix = test_input()
    output = model.predict({"mix": mix})["mask"]
    if output.shape != (1, 4, 1025, 193) or not np.isfinite(output).all():
        raise ValueError("Leap Xe returned invalid predictions.")
    reference = np.array(json.loads(args.reference.read_text()), dtype=np.float32)
    predicted = waveform(mix, output).ravel()[::43]
    snr = 20 * np.log10(np.linalg.norm(reference) / max(np.linalg.norm(predicted - reference), 1e-12))
    print(f"Leap Xe Core ML vocal waveform fidelity: {snr:.1f} dB", flush=True)
    if snr < 30:
        raise ValueError("Leap Xe Core ML predictions differ from the author weights reference.")


if __name__ == "__main__":
    main()
