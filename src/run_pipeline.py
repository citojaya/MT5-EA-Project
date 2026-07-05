import subprocess
import sys
from pathlib import Path

# -------------------------------------------------
# MT5 ML Pipeline
# -------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent

SCRIPTS = [
    "src/data/download_history.py BTCUSD"
    #"src/features/build_features.py",
    #"src/labels/create_regime_labels.py",
    #"src/models/train_stage1_regime.py",
    # "src/live/predict_live_regime.py",   # Uncomment if needed
    #"src/labels/create_trade_labels.py",
    #"src/models/train_stage2_trade.py",
]


def run_script(script_path):
    print("=" * 80)
    print(f"Running: {script_path}")
    print("=" * 80)

    full_path = PROJECT_ROOT / script_path

    result = subprocess.run(
        [sys.executable, str(full_path)],
        cwd=PROJECT_ROOT,
        text=True
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"\nERROR running:\n{script_path}\nExit Code: {result.returncode}"
        )

    print(f"✓ Finished: {script_path}\n")


def main():

    print("\n")
    print("=" * 80)
    print("Starting MT5 Machine Learning Pipeline")
    print("=" * 80)

    for script in SCRIPTS:
        run_script(script)

    print("\n")
    print("=" * 80)
    print("PIPELINE COMPLETED SUCCESSFULLY")
    print("=" * 80)


if __name__ == "__main__":
    main()