#!/usr/bin/env python3
"""
Print release-year distribution for a Pickr SQLite library (movies + movie_genres).

Usage:
  python3 scripts/library_year_stats.py path/to/pickr_library_v1.db
  python3 scripts/library_year_stats.py path/to/pickr_library_v1.db --full   # every calendar year
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser(description="Year/decade stats for Pickr library DB")
    ap.add_argument("db", type=Path, help="Path to pickr_library_v1.db")
    ap.add_argument(
        "--full",
        action="store_true",
        help="Print count for every calendar year (long)",
    )
    args = ap.parse_args()
    path = args.db
    if not path.is_file():
        print(f"Not a file: {path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
    try:
        total = conn.execute("SELECT COUNT(*) FROM movies").fetchone()[0]
        empty = conn.execute(
            """
            SELECT COUNT(*) FROM movies
            WHERE release_date IS NULL OR TRIM(release_date) = ''
            """
        ).fetchone()[0]

        years = conn.execute(
            """
            SELECT substr(release_date, 1, 4) AS y, COUNT(*) AS n
            FROM movies
            WHERE length(release_date) >= 4
              AND substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'
            GROUP BY y
            ORDER BY y
            """
        ).fetchall()

        decades = conn.execute(
            """
            SELECT (CAST(substr(release_date, 1, 4) AS INTEGER) / 10) * 10 AS decade, COUNT(*) AS n
            FROM movies
            WHERE length(release_date) >= 4
              AND substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'
            GROUP BY decade
            ORDER BY decade
            """
        ).fetchall()

        pre2000 = conn.execute(
            """
            SELECT COUNT(*) FROM movies
            WHERE length(release_date) >= 4
              AND CAST(substr(release_date, 1, 4) AS INTEGER) < 2000
            """
        ).fetchone()[0]
        y2000_09 = conn.execute(
            """
            SELECT COUNT(*) FROM movies
            WHERE length(release_date) >= 4
              AND CAST(substr(release_date, 1, 4) AS INTEGER) BETWEEN 2000 AND 2009
            """
        ).fetchone()[0]
        y2010_19 = conn.execute(
            """
            SELECT COUNT(*) FROM movies
            WHERE length(release_date) >= 4
              AND CAST(substr(release_date, 1, 4) AS INTEGER) BETWEEN 2010 AND 2019
            """
        ).fetchone()[0]
        y2020p = conn.execute(
            """
            SELECT COUNT(*) FROM movies
            WHERE length(release_date) >= 4
              AND CAST(substr(release_date, 1, 4) AS INTEGER) >= 2020
            """
        ).fetchone()[0]

        mg = conn.execute("SELECT COUNT(*) FROM movie_genres").fetchone()[0]

        y_min, y_max = years[0][0], years[-1][0] if years else ("?", "?")

    finally:
        conn.close()

    print(f"File: {path.resolve()}")
    print(f"Size: {path.stat().st_size:,} bytes")
    print(f"movies rows: {total:,}  |  movie_genres rows: {mg:,}")
    print(f"release_date empty: {empty}")
    print(f"Year range (present): {y_min}–{y_max} ({len(years)} distinct years)")
    print()
    print("By decade:")
    for dec, n in decades:
        pct = 100.0 * n / total if total else 0
        print(f"  {dec}s: {n:5,}  ({pct:4.1f}%)")
    print()
    print("By era (calendar):")
    print(f"  1980–1999: {pre2000:5,}  ({100.0 * pre2000 / total:4.1f}%)" if total else "  —")
    print(f"  2000–2009: {y2000_09:5,}  ({100.0 * y2000_09 / total:4.1f}%)" if total else "  —")
    print(f"  2010–2019: {y2010_19:5,}  ({100.0 * y2010_19 / total:4.1f}%)" if total else "  —")
    print(f"  2020+:     {y2020p:5,}  ({100.0 * y2020p / total:4.1f}%)" if total else "  —")
    if args.full:
        print()
        print("By calendar year:")
        for y, n in years:
            print(f"  {y}: {n:4}")


if __name__ == "__main__":
    main()
