#!/usr/bin/env python3
import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


SCENE_QUERY = """
query SubmittedFingerprintScenes($input: SceneQueryInput!) {
  queryScenes(input: $input) {
    count
    scenes {
      id
      title
      details
      release_date
      production_date
      duration
      director
      code
      deleted
      studio {
        id
        name
      }
      urls {
        url
        site {
          id
          name
        }
      }
      performers {
        performer {
          id
          name
          disambiguation
        }
        as
      }
      tags {
        id
        name
      }
      fingerprints(is_submitted: true) {
        hash
        algorithm
        duration
        submissions
        reports
        user_submitted
        user_reported
      }
    }
  }
}
"""


def read_secret(name: str, file_name: str, required: bool = True) -> str | None:
    value = os.environ.get(name)
    if value:
        return value.strip()

    path = os.environ.get(file_name)
    if path:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise SystemExit(f"failed to read {file_name}={path}: {exc}") from exc

    if required:
        raise SystemExit(f"missing {name} or {file_name}")
    return None


def graphql(endpoint: str, api_key: str, query: str, variables: dict) -> dict:
    payload = json.dumps({"query": query, "variables": variables}).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "ApiKey": api_key,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"stashdb graphql request failed: HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"stashdb graphql request failed: {exc}") from exc

    decoded = json.loads(body)
    if decoded.get("errors"):
        raise SystemExit(json.dumps(decoded["errors"], indent=2))
    return decoded["data"]


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS runs (
          id INTEGER PRIMARY KEY,
          started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          completed_at TEXT,
          total_scenes INTEGER NOT NULL DEFAULT 0,
          fetched_scenes INTEGER NOT NULL DEFAULT 0,
          page_size INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS scenes (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          details TEXT,
          release_date TEXT,
          production_date TEXT,
          duration INTEGER,
          director TEXT,
          code TEXT,
          deleted INTEGER NOT NULL DEFAULT 0,
          studio_id TEXT,
          studio_name TEXT,
          acquisition_status TEXT NOT NULL DEFAULT 'missing',
          acquisition_notes TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS fingerprints (
          scene_id TEXT NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
          algorithm TEXT NOT NULL,
          hash TEXT NOT NULL,
          duration INTEGER,
          submissions INTEGER,
          reports INTEGER,
          user_submitted INTEGER NOT NULL,
          user_reported INTEGER NOT NULL,
          PRIMARY KEY (scene_id, algorithm, hash)
        );

        CREATE TABLE IF NOT EXISTS scene_urls (
          scene_id TEXT NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
          url TEXT NOT NULL,
          site_id TEXT,
          site_name TEXT,
          PRIMARY KEY (scene_id, url)
        );

        CREATE TABLE IF NOT EXISTS performers (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          disambiguation TEXT
        );

        CREATE TABLE IF NOT EXISTS scene_performers (
          scene_id TEXT NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
          performer_id TEXT NOT NULL REFERENCES performers(id) ON DELETE CASCADE,
          alias TEXT,
          PRIMARY KEY (scene_id, performer_id)
        );

        CREATE TABLE IF NOT EXISTS tags (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS scene_tags (
          scene_id TEXT NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
          tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          PRIMARY KEY (scene_id, tag_id)
        );

        CREATE VIEW IF NOT EXISTS acquisition_list AS
        SELECT
          scenes.id,
          scenes.title,
          scenes.studio_name,
          scenes.release_date,
          scenes.production_date,
          scenes.duration,
          scenes.director,
          scenes.code,
          scenes.acquisition_status,
          scenes.acquisition_notes,
          group_concat(DISTINCT scene_urls.url) AS urls,
          group_concat(DISTINCT performers.name) AS performers,
          group_concat(DISTINCT tags.name) AS tags,
          count(DISTINCT fingerprints.hash) AS submitted_fingerprints
        FROM scenes
        LEFT JOIN scene_urls ON scene_urls.scene_id = scenes.id
        LEFT JOIN scene_performers ON scene_performers.scene_id = scenes.id
        LEFT JOIN performers ON performers.id = scene_performers.performer_id
        LEFT JOIN scene_tags ON scene_tags.scene_id = scenes.id
        LEFT JOIN tags ON tags.id = scene_tags.tag_id
        LEFT JOIN fingerprints ON fingerprints.scene_id = scenes.id
        GROUP BY scenes.id;
        """
    )


def upsert_scene(conn: sqlite3.Connection, scene: dict) -> None:
    studio = scene.get("studio") or {}
    conn.execute(
        """
        INSERT INTO scenes (
          id, title, details, release_date, production_date, duration, director,
          code, deleted, studio_id, studio_name, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        ON CONFLICT(id) DO UPDATE SET
          title = excluded.title,
          details = excluded.details,
          release_date = excluded.release_date,
          production_date = excluded.production_date,
          duration = excluded.duration,
          director = excluded.director,
          code = excluded.code,
          deleted = excluded.deleted,
          studio_id = excluded.studio_id,
          studio_name = excluded.studio_name,
          updated_at = excluded.updated_at
        """,
        (
            scene["id"],
            scene.get("title") or "",
            scene.get("details"),
            scene.get("release_date"),
            scene.get("production_date"),
            scene.get("duration"),
            scene.get("director"),
            scene.get("code"),
            1 if scene.get("deleted") else 0,
            studio.get("id"),
            studio.get("name"),
        ),
    )

    scene_id = scene["id"]
    for table in ("fingerprints", "scene_urls", "scene_performers", "scene_tags"):
        conn.execute(f"DELETE FROM {table} WHERE scene_id = ?", (scene_id,))

    for fingerprint in scene.get("fingerprints") or []:
        conn.execute(
            """
            INSERT OR REPLACE INTO fingerprints (
              scene_id, algorithm, hash, duration, submissions, reports,
              user_submitted, user_reported
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                scene_id,
                fingerprint.get("algorithm") or "",
                fingerprint.get("hash") or "",
                fingerprint.get("duration"),
                fingerprint.get("submissions"),
                fingerprint.get("reports"),
                1 if fingerprint.get("user_submitted") else 0,
                1 if fingerprint.get("user_reported") else 0,
            ),
        )

    for url in scene.get("urls") or []:
        site = url.get("site") or {}
        conn.execute(
            """
            INSERT OR REPLACE INTO scene_urls (scene_id, url, site_id, site_name)
            VALUES (?, ?, ?, ?)
            """,
            (scene_id, url.get("url") or "", site.get("id"), site.get("name")),
        )

    for performer_edge in scene.get("performers") or []:
        performer = performer_edge.get("performer") or {}
        performer_id = performer.get("id")
        if not performer_id:
            continue
        conn.execute(
            """
            INSERT INTO performers (id, name, disambiguation)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              disambiguation = excluded.disambiguation
            """,
            (performer_id, performer.get("name") or "", performer.get("disambiguation")),
        )
        conn.execute(
            """
            INSERT OR REPLACE INTO scene_performers (scene_id, performer_id, alias)
            VALUES (?, ?, ?)
            """,
            (scene_id, performer_id, performer_edge.get("as")),
        )

    for tag in scene.get("tags") or []:
        tag_id = tag.get("id")
        if not tag_id:
            continue
        conn.execute(
            """
            INSERT INTO tags (id, name)
            VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name
            """,
            (tag_id, tag.get("name") or ""),
        )
        conn.execute(
            "INSERT OR REPLACE INTO scene_tags (scene_id, tag_id) VALUES (?, ?)",
            (scene_id, tag_id),
        )


def build(output: Path, page_size: int, limit: int | None, sleep_seconds: float) -> None:
    endpoint = read_secret("STASHDB_GRAPHQL_URL", "STASHDB_GRAPHQL_URL_FILE", required=False)
    endpoint = endpoint or read_secret("STASHDB_GRAPHQL_ENDPOINT", "STASHDB_GRAPHQL_ENDPOINT_FILE")
    api_key = read_secret("STASHDB_API_KEY", "STASHDB_API_KEY_FILE")

    output.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(output)
    init_db(conn)

    run_id = conn.execute(
        "INSERT INTO runs (page_size) VALUES (?) RETURNING id",
        (page_size,),
    ).fetchone()[0]

    fetched = 0
    total = 0
    page = 1
    try:
        while True:
            remaining = None if limit is None else max(limit - fetched, 0)
            if remaining == 0:
                break

            current_page_size = page_size if remaining is None else min(page_size, remaining)
            data = graphql(
                endpoint,
                api_key,
                SCENE_QUERY,
                {
                    "input": {
                        "has_fingerprint_submissions": True,
                        "page": page,
                        "per_page": current_page_size,
                        "sort": "UPDATED_AT",
                        "direction": "DESC",
                    }
                },
            )
            result = data["queryScenes"]
            total = int(result["count"])
            scenes = result["scenes"] or []
            if not scenes:
                break

            with conn:
                for scene in scenes:
                    upsert_scene(conn, scene)

            fetched += len(scenes)
            print(f"page={page} fetched={fetched}/{total}", file=sys.stderr)
            if fetched >= total or (limit is not None and fetched >= limit):
                break
            page += 1
            if sleep_seconds > 0:
                time.sleep(sleep_seconds)
    finally:
        with conn:
            conn.execute(
                """
                UPDATE runs
                SET completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                    total_scenes = ?,
                    fetched_scenes = ?
                WHERE id = ?
                """,
                (total, fetched, run_id),
            )
        conn.close()

    print(f"wrote {fetched} scenes to {output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a SQLite acquisition list from scenes matched by your StashDB fingerprint submissions.",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("~/.local/share/stashdb/acquisition-list.sqlite").expanduser(),
        help="SQLite database to create/update.",
    )
    parser.add_argument("--page-size", type=int, default=100)
    parser.add_argument("--limit", type=int, default=None, help="Fetch at most this many scenes.")
    parser.add_argument("--sleep", type=float, default=0.2, help="Seconds to sleep between pages.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.page_size < 1:
        raise SystemExit("--page-size must be greater than zero")
    build(args.output, args.page_size, args.limit, args.sleep)


if __name__ == "__main__":
    main()
