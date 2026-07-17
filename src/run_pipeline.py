import subprocess
import shlex
import sys
from pathlib import Path


# -------------------------------------------------
# MT5 ML Pipeline
# -------------------------------------------------
symbol = "XAUUSD"
timeframe = "M5"

PROJECT_ROOT = Path(__file__).resolve().parent.parent


RAW_INPUT_FILE = (
        Path("data/raw/ICMarketsAU-Demo") / f"{symbol}_bidask_{timeframe}_20200101_20260716.csv"
)


SCRIPTS = [
   #("src/data/download_history.py", symbol, timeframe, "2020-01-01", "2026-07-16 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"), # download complete history
   #("src/features/build_features.py", symbol, timeframe, "2020-01-01", "2026-07-16 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"), # create features for whole history
   #("src/labels/create_regime_labels.py", symbol, timeframe, "2025-01-01", "2025-12-30 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"), # create labels only witihin training date range
   #("src/models/train_stage1_regime.py", symbol, timeframe, "backtest", "2025-01-01", "2025-12-30 23:59", "--config-file", "config/mt5_config_ICM_DEMO.json"),
   ("src/backtest/backtest.py",symbol,timeframe,"2026-01-01","2026-07-16 23:59","--input-file",str(RAW_INPUT_FILE),"--config-file","config/mt5_config_ICM_DEMO.json"),
   
   #("src/data/extract_ohlc_data.py",symbol,timeframe,"--config","config/mt5_config_ICM_DEMO.json"),
   #("src/backtest/backtest_line_by_line.py",symbol,timeframe,"--input-file",f"data/raw/ohlc_data_{symbol}.csv","--config-file","config/mt5_config_ICM_DEMO.json"),

    # Compare signal regime
    #("src/visualization/compare_signal_regime_confidence.py",
    #    "C:/Users/ctj17/AppData/Roaming/MetaQuotes/Terminal/Common/Files/backtest_line_by_line_XAUUSD.csv",
    #    "C:/Users/ctj17/AppData/Roaming/MetaQuotes/Terminal/Common/Files/XAUUSD_M5_backtest_signals.csv")

    # Compare OHLC files
    #("src/visualization/compare_ohlc_files.py","data/raw/ICMarketsAU-Demo/XAUUSD_bidask_M5_20250101_20260716.csv","data/raw/ICMarketsAU-Demo/XAUUSD_bidask_M5_20250101_20260716_dukascopy.csv")

    # Combine bid,ask files downloaded from Dukascopy using JForex platform
    #("src/data/dukascopy_download.py","--symbol", "XAUUSD","--timeframe", "M5","--start", "2020.01.01","--end", "2026.07.16","--config-file", "config/mt5_config_ICM_DEMO.json")
]


def run_script(step):
    if isinstance(step, str):
        step = tuple(shlex.split(step))

    script_path = step[0]
    script_args = step[1:]
    full_path = PROJECT_ROOT / script_path
    display_command = " ".join([script_path, *script_args])

    if not full_path.is_file():
        raise FileNotFoundError(f"Pipeline script not found: {full_path}")

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

    raw_input_path = PROJECT_ROOT / RAW_INPUT_FILE
    if raw_input_path.is_file():
        print(f"Raw input: {raw_input_path}")
    else:
        print(f"Raw input missing: {raw_input_path}")
        print("Continuing pipeline; steps that require this file will be skipped.")

    for step in SCRIPTS:
        if str(RAW_INPUT_FILE) in step and not raw_input_path.is_file():
            print(f"Skipped {step[0]} because RAW_INPUT_FILE is missing.")
            continue
        run_script(step)

    print("\n")
    print("=" * 80)
    print("PIPELINE COMPLETED SUCCESSFULLY")
    print("=" * 80)


if __name__ == "__main__":
    main()
