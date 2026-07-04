import pandas as pd
import matplotlib.pyplot as plt


INPUT_FILE = "data/labels/XAUUSD_M5_regime_labels.csv"
OUTPUT_FILE = "reports/figures/XAUUSD_M5_regime_labels_selected_period.png"

START_TIME = "2026-06-01 01:00:00"
END_TIME = "2026-06-30 20:00:00"


REGIME_COLORS = {
    0: "green",
    1: "lime",
    2: "red",
    3: "orange",
    4: "blue",
    5: "purple",
    6: "gray",
    7: "black",
}


def plot_regimes(df: pd.DataFrame):
    df = df.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)

    start_time = pd.to_datetime(START_TIME, utc=True)
    end_time = pd.to_datetime(END_TIME, utc=True)

    df = df[(df["time"] >= start_time) & (df["time"] <= end_time)]

    if df.empty:
        print("No data found for the selected time period.")
        return

    plt.figure(figsize=(18, 8))

    plt.plot(
        df["time"],
        df["close"],
        color="lightgray",
        linewidth=1,
        label="Close",
    )

    for regime, group in df.groupby("regime"):
        regime_name = group["regime_name"].iloc[0]

        plt.scatter(
            group["time"],
            group["close"],
            s=12,
            color=REGIME_COLORS.get(regime, "black"),
            label=f"{regime}: {regime_name}",
        )

    plt.title(f"Market Regime Labels from {START_TIME} to {END_TIME}")
    plt.xlabel("Time")
    plt.ylabel("Close Price")
    plt.legend()
    plt.grid(True)
    plt.tight_layout()

    plt.savefig(OUTPUT_FILE, dpi=150)
    plt.show()

    print(f"Saved plot to: {OUTPUT_FILE}")
    print(f"Rows plotted: {len(df)}")


def main():
    df = pd.read_csv(INPUT_FILE)
    plot_regimes(df)


if __name__ == "__main__":
    main()