#!/usr/bin/env python3
"""
Emit moviefinderTests/Fixtures/pickr_library_minimal.db — tiny schema-identical DB for unit tests.
Run from repo root: python3 scripts/make_minimal_library_fixture.py
"""
import json
import os
import sqlite3

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "moviefinderTests", "pickr_library_minimal.db")


def main():
    if os.path.exists(OUT):
        os.remove(OUT)
    conn = sqlite3.connect(OUT)
    conn.executescript(
        """
        CREATE TABLE movies (
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
        CREATE TABLE movie_genres (
            movie_id  INTEGER NOT NULL,
            genre_id  INTEGER NOT NULL,
            PRIMARY KEY (movie_id, genre_id)
        );
        CREATE INDEX idx_mg_genre ON movie_genres(genre_id);
        CREATE INDEX idx_movies_pop ON movies(popularity DESC);
    """
    )
    rows = [
        (
            100_001,
            "Fixture Action Alpha",
            "alpha",
            "2020-01-01",
            "/a.jpg",
            None,
            7.5,
            1000,
            100.0,
            json.dumps([28]),
            [(100_001, 28)],
        ),
        (
            100_002,
            "Fixture Comedy Beta",
            "beta",
            "2019-06-15",
            "/b.jpg",
            None,
            6.8,
            800,
            50.0,
            json.dumps([35]),
            [(100_002, 35)],
        ),
        (
            100_003,
            "Fixture Horror Gamma",
            "gamma",
            "2018-03-20",
            "/c.jpg",
            None,
            6.0,
            400,
            10.0,
            json.dumps([27]),
            [(100_003, 27)],
        ),
    ]
    for r in rows:
        mid, title, ov, rd, pp, bp, va, vc, pop, gj, pairs = r
        conn.execute(
            """INSERT INTO movies (id, title, overview, release_date, poster_path, backdrop_path,
               vote_average, vote_count, popularity, genre_ids_json)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (mid, title, ov, rd, pp, bp or "", va, vc, pop, gj),
        )
        for movie_id, gid in pairs:
            conn.execute(
                "INSERT INTO movie_genres (movie_id, genre_id) VALUES (?,?)",
                (movie_id, gid),
            )
    conn.commit()
    conn.close()
    print(f"Wrote {OUT} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
