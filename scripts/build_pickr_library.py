#!/usr/bin/env python3
"""
build_pickr_library.py
Pickr — One-time (and annual) library builder.

Usage:
    pip install requests
    TMDB_API_KEY=your_key python scripts/build_pickr_library.py

Output: pickr_library_v1.db  (~10–20 MB)
Upload this file to your CDN and update LIBRARY_CDN_URL in MovieLibraryService.swift.
"""

import sqlite3
import time
import os
import json

import requests

# ── Config ───────────────────────────────────────────────────────────────────
API_KEY = os.environ.get("TMDB_API_KEY", "YOUR_TMDB_API_KEY")
BASE = "https://api.themoviedb.org/3"
DB_PATH = "pickr_library_v1.db"

# Genres must exactly match GenreCatalog.onboarding in GenrePreferences.swift
GENRES = [
    (28, "Action"),
    (35, "Comedy"),
    (18, "Drama"),
    (53, "Thriller"),
    (27, "Horror"),
    (10749, "Romance"),
    (878, "Sci-Fi"),
    (99, "Documentary"),
    (10751, "Family"),
]

EARLY_YEARS = range(1980, 2000)
RECENT_YEARS = range(2000, 2026)

# Historical defaults were 50 (pre-2000) and 100 (2000+) per genre/year — that overweighted
# the 2010s in the final DB. Use tiered targets to pull more classics and cap the modern peak.
# After changing, rebuild, then `python3 scripts/library_year_stats.py pickr_library_v1.db` and
# upload to CDN; bump DB filename if you need side-by-side clients.
MIN_VOTE_COUNT = 500  # must have real audience awareness
REQUESTS_PER_SECOND = 8  # safely under TMDB's 50/s limit


def target_for_year(year: int) -> int:
    """TMDB pulls per genre+year; higher = more rows for that year in the final DB."""
    if year < 1990:
        return 72
    if year < 2000:
        return 78
    if year < 2010:
        return 88
    if year < 2020:
        return 82  # was 100 — flattens the 2010s spike
    return 80


def min_vote_count_for_year(year: int) -> int:
    """Slightly lower floor pre-2000 so discover returns enough pages for older years."""
    if year < 1990:
        return 300
    if year < 2000:
        return 400
    return MIN_VOTE_COUNT


# ── Database setup ────────────────────────────────────────────────────────────
def init_db(conn):
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS movies (
            id              INTEGER PRIMARY KEY,
            title           TEXT    NOT NULL,
            overview        TEXT    DEFAULT '',
            release_date    TEXT    DEFAULT '',
            poster_path     TEXT    DEFAULT '',
            backdrop_path   TEXT    DEFAULT '',
            vote_average    REAL    DEFAULT 0,
            vote_count      INTEGER DEFAULT 0,
            popularity      REAL    DEFAULT 0,
            genre_ids_json  TEXT    DEFAULT '[]'
        );

        CREATE TABLE IF NOT EXISTS movie_genres (
            movie_id  INTEGER NOT NULL REFERENCES movies(id),
            genre_id  INTEGER NOT NULL,
            PRIMARY KEY (movie_id, genre_id)
        );

        CREATE INDEX IF NOT EXISTS idx_mg_genre ON movie_genres(genre_id);
        CREATE INDEX IF NOT EXISTS idx_movies_pop ON movies(popularity DESC);
    """
    )
    conn.commit()


# ── TMDB helpers ──────────────────────────────────────────────────────────────
def discover_page(genre_id, year, page, min_vote_count: int):
    r = requests.get(
        f"{BASE}/discover/movie",
        params={
            "api_key": API_KEY,
            "language": "en-US",
            "include_adult": "false",
            "with_runtime.gte": 60,
            "vote_count.gte": min_vote_count,
            "sort_by": "popularity.desc",
            "with_genres": genre_id,
            "primary_release_year": year,
            "page": page,
        },
        timeout=15,
    )
    r.raise_for_status()
    return r.json()


def fetch_titles_for(genre_id, year, target):
    """Paginate TMDB until we have `target` movies for a genre+year combo."""
    movies = []
    pages_needed = (target + 19) // 20  # TMDB returns 20 per page
    vfloor = min_vote_count_for_year(year)
    for page in range(1, pages_needed + 1):
        try:
            data = discover_page(genre_id, year, page, vfloor)
        except Exception as e:
            print(f"  WARN {genre_id}/{year}/p{page}: {e}")
            break
        movies.extend(data.get("results", []))
        if page >= data.get("total_pages", 1):
            break
        time.sleep(1.0 / REQUESTS_PER_SECOND)
    return movies[:target]


# ── Insert helpers ─────────────────────────────────────────────────────────────
def upsert_movie(conn, m):
    genre_ids = m.get("genre_ids", [])
    conn.execute(
        """
        INSERT OR IGNORE INTO movies
            (id, title, overview, release_date, poster_path, backdrop_path,
             vote_average, vote_count, popularity, genre_ids_json)
        VALUES (?,?,?,?,?,?,?,?,?,?)
    """,
        (
            m["id"],
            m.get("title", ""),
            m.get("overview", ""),
            m.get("release_date", ""),
            m.get("poster_path") or "",
            m.get("backdrop_path") or "",
            m.get("vote_average", 0),
            m.get("vote_count", 0),
            m.get("popularity", 0),
            json.dumps(genre_ids),
        ),
    )
    for gid in genre_ids:
        conn.execute(
            "INSERT OR IGNORE INTO movie_genres (movie_id, genre_id) VALUES (?,?)",
            (m["id"], gid),
        )


# ── Main ───────────────────────────────────────────────────────────────────────
def build():
    print(f"Building Pickr library -> {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    init_db(conn)

    for gi, (genre_id, genre_name) in enumerate(GENRES, 1):
        print(f"\n[{gi}/{len(GENRES)}] {genre_name} (id={genre_id})")
        for year in list(EARLY_YEARS) + list(RECENT_YEARS):
            target = target_for_year(year)
            movies = fetch_titles_for(genre_id, year, target)
            for m in movies:
                upsert_movie(conn, m)
            conn.commit()
            print(f"  {year}: {len(movies)} titles stored", end="\r", flush=True)
            time.sleep(1.0 / REQUESTS_PER_SECOND)
        print()

    count = conn.execute("SELECT COUNT(*) FROM movies").fetchone()[0]
    print(f"\nDone. {count:,} unique movies in {DB_PATH}")
    conn.close()


if __name__ == "__main__":
    build()
