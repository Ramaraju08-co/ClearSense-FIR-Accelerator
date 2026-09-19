from pathlib import Path

import numpy as np
import matplotlib.pyplot as plt


# ---------------------------------------------------------
# ClearSense deterministic sensor-noise experiment
# ---------------------------------------------------------

SAMPLE_RATE = 100.0
NUM_SAMPLES = 4096

DATA_W = 16
FRAC_W = 15
TAPS = 16

NOISE_STD = 950.0
RNG_SEED = 2026

RESULT_DIR = Path("results/analysis")
RESULT_DIR.mkdir(parents=True, exist_ok=True)


def saturate_signed(value: int, width: int) -> int:
    maximum = (1 << (width - 1)) - 1
    minimum = -(1 << (width - 1))

    return max(min(value, maximum), minimum)


def round_symmetric(value: int, frac_w: int) -> int:
    if frac_w == 0:
        return value

    half_lsb = 1 << (frac_w - 1)

    if value >= 0:
        return (value + half_lsb) >> frac_w

    return -(((-value) + half_lsb) >> frac_w)


def fixed_point_fir(samples, coefficients):
    history = [0] * len(coefficients)
    output = []

    for sample in samples:
        acc = sample * coefficients[0]

        for tap in range(1, len(coefficients)):
            acc += history[tap - 1] * coefficients[tap]

        filtered = round_symmetric(acc, FRAC_W)
        filtered = saturate_signed(filtered, DATA_W)

        output.append(filtered)

        for tap in range(len(history) - 1, 0, -1):
            history[tap] = history[tap - 1]

        history[0] = int(sample)

    return np.asarray(output, dtype=np.int64)


# ---------------------------------------------------------
# Generate deterministic synthetic environmental signal
# ---------------------------------------------------------

time = np.arange(NUM_SAMPLES) / SAMPLE_RATE

clean_signal = (
    12000
    + 900 * np.sin(2 * np.pi * 0.06 * time)
    + 450 * np.sin(2 * np.pi * 0.015 * time)
)

# Environmental event 1
clean_signal[(time >= 12.0) & (time < 15.0)] += 3000

# Environmental event 2
clean_signal[(time >= 18.0) & (time < 22.0)] += 1800

rng = np.random.default_rng(RNG_SEED)

noise = rng.normal(
    loc=0.0,
    scale=NOISE_STD,
    size=NUM_SAMPLES
)

noisy_signal = np.rint(
    clean_signal + noise
).astype(np.int64)

sample_max = (1 << (DATA_W - 1)) - 1
sample_min = -(1 << (DATA_W - 1))

noisy_signal = np.clip(
    noisy_signal,
    sample_min,
    sample_max
)


# ---------------------------------------------------------
# Q1.15 16-tap moving-average coefficients
# ---------------------------------------------------------

coefficient_value = (1 << FRAC_W) // TAPS

coefficients = np.full(
    TAPS,
    coefficient_value,
    dtype=np.int64
)

filtered_signal = fixed_point_fir(
    noisy_signal,
    coefficients
)


# ---------------------------------------------------------
# Signal-quality metrics
# ---------------------------------------------------------

STARTUP_IGNORE = 64

valid_slice = slice(
    STARTUP_IGNORE,
    None
)

input_residual = (
    noisy_signal[valid_slice]
    - clean_signal[valid_slice]
)

output_residual = (
    filtered_signal[valid_slice]
    - clean_signal[valid_slice]
)

input_rms = np.sqrt(
    np.mean(
        np.square(input_residual)
    )
)

output_rms = np.sqrt(
    np.mean(
        np.square(output_residual)
    )
)

noise_reduction_db = 20.0 * np.log10(
    input_rms / output_rms
)


print("")
print("==========================================")
print(" ClearSense Sensor-Noise Analysis")
print("==========================================")

print(
    f"Input residual-noise RMS : "
    f"{input_rms:.3f} counts"
)

print(
    f"Output residual-noise RMS: "
    f"{output_rms:.3f} counts"
)

print(
    f"Residual-noise reduction : "
    f"{noise_reduction_db:.3f} dB"
)

print("==========================================")
print("")


# ---------------------------------------------------------
# Save trace CSV
# ---------------------------------------------------------

trace = np.column_stack(
    (
        time,
        clean_signal,
        noisy_signal,
        filtered_signal,
    )
)

np.savetxt(
    RESULT_DIR / "sensor_trace.csv",
    trace,
    delimiter=",",
    header=(
        "time_seconds,"
        "clean_signal,"
        "noisy_signal,"
        "clearsense_output"
    ),
    comments="",
)


# ---------------------------------------------------------
# Plot sensor filtering result
# ---------------------------------------------------------

plt.figure(figsize=(11, 6))

plt.plot(
    time,
    noisy_signal,
    alpha=0.35,
    label="Noisy sensor"
)

plt.plot(
    time,
    clean_signal,
    linewidth=1.5,
    label="Underlying signal"
)

plt.plot(
    time,
    filtered_signal,
    linewidth=1.5,
    label="ClearSense output"
)

plt.xlabel("Time (s)")
plt.ylabel("ADC counts")
plt.title(
    "Synthetic Environmental-Sensor Experiment"
)

plt.legend()
plt.grid(True)

plt.tight_layout()

plt.savefig(
    RESULT_DIR / "sensor_filtering.png",
    dpi=160
)

plt.close()


# ---------------------------------------------------------
# Frequency response of 16-tap moving-average FIR
# ---------------------------------------------------------

impulse_response = (
    coefficients.astype(float)
    / float(1 << FRAC_W)
)

fft_points = 8192

response = np.fft.rfft(
    impulse_response,
    n=fft_points
)

frequency = np.fft.rfftfreq(
    fft_points,
    d=1.0
)

magnitude_db = 20.0 * np.log10(
    np.maximum(
        np.abs(response),
        1e-12
    )
)

plt.figure(figsize=(10, 6))

plt.plot(
    frequency,
    magnitude_db
)

plt.xlim(
    0.0,
    0.5
)

plt.xlabel(
    "Normalized frequency (cycles/sample)"
)

plt.ylabel(
    "Magnitude (dB)"
)

plt.title(
    "16-Tap Moving-Average Frequency Response"
)

plt.grid(True)

plt.tight_layout()

plt.savefig(
    RESULT_DIR / "frequency_response.png",
    dpi=160
)

plt.close()


# ---------------------------------------------------------
# Save metrics
# ---------------------------------------------------------

with open(
    RESULT_DIR / "metrics.txt",
    "w",
    encoding="utf-8"
) as file:

    file.write(
        f"Input residual-noise RMS: "
        f"{input_rms:.3f} counts\n"
    )

    file.write(
        f"Output residual-noise RMS: "
        f"{output_rms:.3f} counts\n"
    )

    file.write(
        f"Residual-noise reduction: "
        f"{noise_reduction_db:.3f} dB\n"
    )


print(
    "Analysis files written to "
    "results/analysis/"
)
