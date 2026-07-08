#!/usr/bin/env python3
import argparse
import json
import os
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path


def iso(dt):
    return dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write_session(path, session_id, cwd, title, body, ready_token):
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        {
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "cwd": cwd,
            },
        },
        {
            "type": "response_item",
            "payload": {
                "type": "message",
                "role": "user",
                "content": [{"text": title}],
            },
        },
        {
            "type": "response_item",
            "payload": {
                "type": "message",
                "role": "assistant",
                "phase": "final_answer",
                "content": [{"text": body}],
            },
        },
    ]
    if ready_token:
        lines.append(
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "phase": "final_answer",
                    "content": [{"text": ready_token}],
                },
            }
        )
    path.write_text("\n".join(json.dumps(line, separators=(",", ":")) for line in lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Create a disposable fake Codex home for Attaché smoke tests.")
    parser.add_argument("--home", required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--needle", default="")
    parser.add_argument("--target-title", default="")
    parser.add_argument("--large-target", action="store_true")
    args = parser.parse_args()

    home = Path(args.home)
    sessions = home / "sessions"
    archived = home / "archived_sessions"
    automations = home / "automations"
    for directory in [sessions, archived, automations]:
        directory.mkdir(parents=True, exist_ok=True)
    (home / "session_index.jsonl").write_text("", encoding="utf-8")
    (home / "config.toml").write_text(
        'sandbox_mode = "read-only"\napproval_policy = "never"\nmodel_reasoning_effort = "low"\n',
        encoding="utf-8",
    )

    count = max(1, args.count)
    target_index = min(count - 1, max(0, count // 2))
    now = datetime.now(timezone.utc)
    day_dir = sessions / now.strftime("%Y") / now.strftime("%m") / now.strftime("%d")
    cwd = f"/tmp/attache-fake-codex-{args.nonce}"
    needle = args.needle or f"ATTACHE_LOAD_NEEDLE_{args.nonce}"
    target_title = args.target_title or f"Load smoke target {args.nonce}"
    target_session_id = ""
    target_session_file = ""

    index_lines = []
    for i in range(count):
        session_id = str(uuid.uuid4())
        updated = now - timedelta(seconds=i)
        prefix = updated.strftime("rollout-%Y-%m-%dT%H-%M-%S")
        path = day_dir / f"{prefix}-{session_id}.jsonl"
        if i == target_index:
            title = target_title
            filler = " ".join(f"large-transcript-{n}" for n in range(6000)) if args.large_target else ""
            body = f"{needle} target transcript for {args.nonce}. {filler}"
            ready_token = f"ATTACHE_READY_{args.nonce}"
            target_session_id = session_id
            target_session_file = str(path)
        else:
            title = f"Load smoke background {args.nonce} {i:03d}"
            body = f"Background fake Codex transcript {i:03d} for {args.nonce}."
            ready_token = ""
        write_session(path, session_id, cwd, title, body, ready_token)
        index_lines.append(
            json.dumps(
                {
                    "id": session_id,
                    "thread_name": title,
                    "updated_at": iso(updated),
                },
                separators=(",", ":"),
            )
        )

    (home / "session_index.jsonl").write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    os.chmod(home / "session_index.jsonl", 0o600)
    os.chmod(home / "config.toml", 0o600)

    print(
        json.dumps(
            {
                "target_session_id": target_session_id,
                "target_session_file": target_session_file,
                "target_title": target_title,
                "needle": needle,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
