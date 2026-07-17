#!/usr/bin/env python3
"""Create a disposable fake Grok Build home for Attaché tests (INF-361).

Grok Build stores sessions at
~/.grok/sessions/<percent-encoded-project-path>/<session-uuid>/, containing
chat_history.jsonl (the narratable transcript: user/assistant/tool_result
records with `content` and `type` keys, no per-line timestamp), events.jsonl,
hunk_records.jsonl, plan.md, plan_mode.json, and images/ (verified against
real sessions on this Mac, 2026-07-16). A sibling prompt_history.jsonl sits at
the encoded-project level, and session_search.sqlite at the sessions root.

Unlike create-fake-codex-home.py, this fixture does not need a fake `grok`
executable: INF-361 is watch-tier only (discovery, indexing, live narration,
attention), not two-way delivery, so nothing resumes a fake CLI process
against these fixtures. If a later Tier 2 ticket adds Grok two-way delivery,
mirror create-fake-codex-home.py's FAKE_CODEX_SCRIPT pattern here.
"""
import argparse
import json
import os
import uuid
from urllib.parse import quote
from pathlib import Path


def write_chat_history(path, needle, target_title, ready_token):
    """Write a chat_history.jsonl matching Grok Build's real record shapes:
    system (skipped), user (content is a [{type:"text", text}] block list),
    assistant (content is a plain string, optional tool_calls), tool_result
    (content is a plain string, references tool_call_id).
    """
    lines = [
        {"type": "system", "content": "You are Grok Build, an agentic coding assistant."},
        {"type": "user", "content": [{"type": "text", "text": target_title}], "synthetic_reason": None},
        {
            "type": "assistant",
            "content": f"{needle} looking into it now.",
            "model_id": "grok-4-fast",
            "reasoning": None,
            "tool_calls": [{"id": "call_1", "name": "Bash", "arguments": {"command": "ls"}}],
        },
        {"type": "tool_result", "content": "file1.txt\nfile2.txt", "tool_call_id": "call_1"},
        {
            "type": "assistant",
            "content": f"{needle} done: {ready_token}" if ready_token else f"{needle} done.",
            "model_id": "grok-4-fast",
            "reasoning": None,
            "tool_calls": None,
        },
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(json.dumps(line, separators=(",", ":")) for line in lines) + "\n",
        encoding="utf-8",
    )


def write_plan_md(path, heading):
    path.write_text(f"# {heading}\n\nSteps go here.\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Create a disposable fake Grok Build home for Attaché tests.")
    parser.add_argument("--home", required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--needle", default="")
    parser.add_argument("--target-title", default="")
    parser.add_argument("--project-cwd", default="")
    parser.add_argument("--with-plan-md", action="store_true", help="Give the target session a plan.md heading title")
    args = parser.parse_args()

    home = Path(args.home)
    sessions_root = home / "sessions"
    sessions_root.mkdir(parents=True, exist_ok=True)

    needle = args.needle or f"ATTACHE_LOAD_NEEDLE_{args.nonce}"
    target_title = args.target_title or f"Load smoke target {args.nonce}"
    ready_token = f"ATTACHE_READY_{args.nonce}"
    # A project path with a space and a non-ASCII character, so decoding
    # tests exercise both (INF-361 acceptance: "percent-decoding of project
    # paths, including spaces and non-ASCII").
    project_cwd = args.project_cwd or f"/Users/tester/Grok Projects/café-{args.nonce}"
    encoded_project = quote(project_cwd, safe="")
    project_dir = sessions_root / encoded_project
    project_dir.mkdir(parents=True, exist_ok=True)
    (project_dir / "prompt_history.jsonl").write_text("", encoding="utf-8")
    (sessions_root / "session_search.sqlite").write_bytes(b"")

    count = max(1, args.count)
    target_index = min(count - 1, max(0, count // 2))
    target_session_id = ""
    target_session_file = ""

    for i in range(count):
        session_id = str(uuid.uuid4())
        session_dir = project_dir / session_id
        session_dir.mkdir(parents=True, exist_ok=True)
        (session_dir / "images").mkdir(exist_ok=True)
        (session_dir / "hunk_records.jsonl").write_text("", encoding="utf-8")
        (session_dir / "events.jsonl").write_text("", encoding="utf-8")

        is_target = i == target_index
        title = target_title if is_target else f"Load smoke background {args.nonce} {i:03d}"
        write_chat_history(
            session_dir / "chat_history.jsonl",
            needle=needle if is_target else f"background {i:03d}",
            target_title=title,
            ready_token=ready_token if is_target else "",
        )
        if is_target and args.with_plan_md:
            write_plan_md(session_dir / "plan.md", title)
            target_session_file = str(session_dir / "chat_history.jsonl")
            target_session_id = session_id
        elif is_target:
            target_session_file = str(session_dir / "chat_history.jsonl")
            target_session_id = session_id

    print(
        json.dumps(
            {
                "target_session_id": target_session_id,
                "target_session_file": target_session_file,
                "target_title": target_title,
                "needle": needle,
                "ready_token": ready_token,
                "project_cwd": project_cwd,
                "encoded_project_dir": str(project_dir),
                "sessions_root": str(sessions_root),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
