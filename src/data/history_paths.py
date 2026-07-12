import json
import re
from datetime import datetime
from pathlib import Path


RAW_DIR = Path("data/raw")


def sanitize_directory_name(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*]+', "_", value.strip())
    cleaned = re.sub(r"\s+", "_", cleaned)
    return cleaned or "unknown_broker"


def load_config(config_file: str | Path) -> dict:
    config_path = Path(config_file)
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def broker_name_from_config(cfg: dict, config_file: str | Path) -> str:
    broker = cfg.get("broker") or cfg.get("server") or Path(config_file).stem
    return sanitize_directory_name(str(broker))


def raw_dir_for_config(
    config_file: str | Path | None = None,
    cfg: dict | None = None,
    base_dir: Path = RAW_DIR,
) -> Path:
    if cfg is None and config_file is not None and Path(config_file).exists():
        cfg = load_config(config_file)

    if cfg is None:
        return base_dir

    return base_dir / broker_name_from_config(cfg, config_file or "")


def raw_history_filename(
    symbol: str,
    timeframe: str,
    date_from: datetime | str,
    date_to: datetime | str,
) -> str:
    return (
        f"{symbol}_bidask_{timeframe}_"
        f"{format_date_token(date_from)}_{format_date_token(date_to)}.csv"
    )


def raw_history_path(
    raw_dir: Path,
    symbol: str,
    timeframe: str,
    date_from: datetime | str,
    date_to: datetime | str,
) -> Path:
    return raw_dir / raw_history_filename(symbol, timeframe, date_from, date_to)


def format_date_token(value: datetime | str) -> str:
    if isinstance(value, datetime):
        return value.strftime("%Y%m%d")
    parsed = pd_style_datetime_parse(value)
    return parsed.strftime("%Y%m%d")


def pd_style_datetime_parse(value: str) -> datetime:
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y%m%d"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    raise ValueError(
        f"Invalid date '{value}'. Use YYYY-MM-DD, YYYY-MM-DD HH:MM, or YYYYMMDD."
    )


def history_file_sort_key(path: Path) -> tuple[datetime, float]:
    try:
        end_token = path.stem.rsplit("_", maxsplit=1)[-1]
        end_date = datetime.strptime(end_token, "%Y%m%d")
    except ValueError:
        end_date = datetime.min
    return end_date, path.stat().st_mtime


def find_existing_history_file(
    search_dirs: list[Path],
    symbol: str,
    timeframe: str,
) -> Path | None:
    pattern = f"{symbol}_bidask_{timeframe}_*.csv"
    candidates = []
    seen = set()

    for raw_dir in search_dirs:
        for path in raw_dir.glob(pattern):
            if path in seen:
                continue
            seen.add(path)
            candidates.append(path)

    if not candidates:
        return None

    return sorted(candidates, key=history_file_sort_key, reverse=True)[0]
