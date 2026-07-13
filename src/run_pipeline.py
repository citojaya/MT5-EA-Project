import subprocess
import shlex
import sys
from pathlib import Path


# -------------------------------------------------
# MT5 ML Pipeline
# -------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent

SCRIPTS = [
   ("src/data/download_history.py", "XAUUSD", "M5", "2025-01-01", "2026-12-30 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"), # download complete history
   ("src/features/build_features.py", "XAUUSD", "M5", "2025-01-01", "2026-12-30 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"), # create lables for whole history
   ("src/labels/create_regime_labels.py", "XAUUSD", "M5", "2025-01-01", "2026-06-30 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"), # create labels only witihin trainin date range
   ("src/models/train_stage1_regime.py", "XAUUSD", "M5", "backtest", "2025-01-01", "2026-06-30 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"),
   ("src/backtest/backtest.py", "XAUUSD", "M5", "2026-07-10", "2026-07-12 23:59", "--rebuild-features", "--config-file", "config/mt5_config_ICM_DEMO.json"),

   #("src/backtest/backtest_line_by_line.py", "XAUUSD", "M5", "--config-file", "config/mt5_config_ICM_DEMO.json")
   #("src/backtest/backtest.py", "XAUUSD", "M5", "2025-07-10", "2026-07-12 23:59")
    #("src/data/extract_ohlc_data.py"),
    #("src/backtest/backtest_line_by_line.py","XAUUSD","M5", "--config-file", "config/mt5_config_ICM_DEMO.json")

    # ("src/live/predict_live_regime.py",),  # Uncomment if needed
    # ("src/labels/create_trade_labels.py",),
    # ("src/models/train_stage2_trade.py",),
]


def run_script(step):
    if isinstance(step, str):
        step = tuple(shlex.split(step))

    script_path = step[0]
    script_args = step[1:]
    full_path = PROJECT_ROOT / script_path
    display_command = " ".join([script_path, *script_args])

    print("=" * 80)
    print(f"Running: {display_command}")
    print("=" * 80)

    result = subprocess.run(
        [sys.executable, str(full_path), *script_args],
        cwd=PROJECT_ROOT,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"\nERROR running:\n{display_command}\nExit Code: {result.returncode}"
        )

    print(f"Finished: {display_command}\n")


def main():
    print("\n")
    print("=" * 80)
    print("Starting MT5 Machine Learning Pipeline")
    print("=" * 80)

    for step in SCRIPTS:
        run_script(step)

    print("\n")
    print("=" * 80)
    print("PIPELINE COMPLETED SUCCESSFULLY")
    print("=" * 80)


if __name__ == "__main__":
    main()
