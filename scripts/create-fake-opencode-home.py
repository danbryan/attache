#!/usr/bin/env python3
"""Create a disposable fake opencode data home for Attaché tests (INF-362).

opencode stores sessions as rows in one shared SQLite database at
~/.local/share/opencode/opencode.db (WAL mode; verified against real sessions
on this Mac, 2026-07-17). Tables sampled: session (id, project_id,
workspace_id, directory, title, time_created, time_updated, time_archived,
...), message (id, session_id, data JSON, time_created), part (id,
message_id, session_id, data JSON), project, project_directory, workspace.
`message.data.role` is "user"/"assistant"; `message.data.finish` is "stop" on
a completed assistant turn (opencode's only turn-boundary marker, unlike
Codex's `phase == "final_answer"`). `part.data.type` is "text" for
narratable content (also seen: "reasoning", "tool", "step-start",
"step-finish", none narrated).

Unlike create-fake-codex-home.py, this fixture does not need a fake
`opencode` executable: INF-362 is watch-tier only (discovery, indexing), not
two-way delivery, so nothing resumes a fake CLI process against these
fixtures. Written with the sqlite3 module directly (not the CLI) so it has no
non-stdlib dependency.
"""
import argparse
import json
import sqlite3
import uuid
from pathlib import Path


SCHEMA = """
CREATE TABLE session (
    id text PRIMARY KEY,
    project_id text,
    workspace_id text,
    directory text NOT NULL,
    title text NOT NULL,
    parent_id text,
    time_created integer NOT NULL,
    time_updated integer NOT NULL,
    time_archived integer
);
CREATE TABLE message (
    id text PRIMARY KEY,
    session_id text NOT NULL,
    data text NOT NULL,
    time_created integer NOT NULL
);
CREATE TABLE part (
    id text PRIMARY KEY,
    message_id text NOT NULL,
    session_id text NOT NULL,
    data text NOT NULL
);
"""


def write_session(conn, session_id, directory, title, needle, ready_token, time_base):
    conn.execute(
        "INSERT INTO session (id, directory, title, time_created, time_updated, time_archived) VALUES (?, ?, ?, ?, ?, NULL)",
        (session_id, directory, title, time_base, time_base + 5000),
    )

    user_msg_id = f"msg_{uuid.uuid4().hex}"
    conn.execute(
        "INSERT INTO message (id, session_id, data, time_created) VALUES (?, ?, ?, ?)",
        (user_msg_id, session_id, json.dumps({"role": "user"}), time_base),
    )
    conn.execute(
        "INSERT INTO part (id, message_id, session_id, data) VALUES (?, ?, ?, ?)",
        (f"{user_msg_id}-p0", user_msg_id, session_id, json.dumps({"type": "text", "text": title})),
    )

    assistant_msg_id = f"msg_{uuid.uuid4().hex}"
    conn.execute(
        "INSERT INTO message (id, session_id, data, time_created) VALUES (?, ?, ?, ?)",
        (assistant_msg_id, session_id, json.dumps({"role": "assistant", "finish": "stop"}), time_base + 5000),
    )
    reply = f"{needle} done: {ready_token}" if ready_token else f"{needle} done."
    conn.execute(
        "INSERT INTO part (id, message_id, session_id, data) VALUES (?, ?, ?, ?)",
        (f"{assistant_msg_id}-p0", assistant_msg_id, session_id, json.dumps({"type": "text", "text": f"{needle} looking into it now."})),
    )
    conn.execute(
        "INSERT INTO part (id, message_id, session_id, data) VALUES (?, ?, ?, ?)",
        (f"{assistant_msg_id}-p1", assistant_msg_id, session_id, json.dumps({"type": "text", "text": reply})),
    )


def main():
    parser = argparse.ArgumentParser(description="Create a disposable fake opencode data home for Attaché tests.")
    parser.add_argument("--data-home", required=True, help="Directory that will hold opencode.db (the XDG_DATA_HOME/opencode dir)")
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--needle", default="")
    parser.add_argument("--target-title", default="")
    parser.add_argument("--project-cwd", default="")
    args = parser.parse_args()

    data_home = Path(args.data_home)
    data_home.mkdir(parents=True, exist_ok=True)
    db_path = data_home / "opencode.db"

    needle = args.needle or f"ATTACHE_LOAD_NEEDLE_{args.nonce}"
    target_title = args.target_title or f"Load smoke target {args.nonce}"
    ready_token = f"ATTACHE_READY_{args.nonce}"
    project_cwd = args.project_cwd or f"/Users/tester/opencode-projects/proj-{args.nonce}"

    conn = sqlite3.connect(str(db_path))
    conn.executescript(SCHEMA)
    conn.execute("PRAGMA journal_mode=WAL")

    count = max(1, args.count)
    target_index = min(count - 1, max(0, count // 2))
    target_session_id = ""

    for i in range(count):
        session_id = f"ses_{uuid.uuid4().hex}"
        is_target = i == target_index
        title = target_title if is_target else f"Load smoke background {args.nonce} {i:03d}"
        write_session(
            conn,
            session_id=session_id,
            directory=project_cwd if is_target else f"{project_cwd}-bg-{i:03d}",
            title=title,
            needle=needle if is_target else f"background {i:03d}",
            ready_token=ready_token if is_target else "",
            time_base=1_700_000_000_000 + i * 1000,
        )
        if is_target:
            target_session_id = session_id

    conn.commit()
    conn.close()

    print(
        json.dumps(
            {
                "target_session_id": target_session_id,
                "target_title": target_title,
                "needle": needle,
                "ready_token": ready_token,
                "project_cwd": project_cwd,
                "database_path": str(db_path),
                "data_home": str(data_home),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
