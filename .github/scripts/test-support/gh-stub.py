#!/usr/bin/env python3
"""Model the GitHub CLI contracts used by upstream-sync tests."""

from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import sys
from typing import Any


def arg_value(args: list[str], flag: str) -> str | None:
    for index, item in enumerate(args):
        if item == flag and index + 1 < len(args):
            return args[index + 1]
    return None


def selector(args: list[str], start: int = 2) -> str | None:
    value_flags = {"--repo", "--title", "--add-label", "--remove-label", "--body"}
    skip = False
    for item in args[start:]:
        if skip:
            skip = False
            continue
        if item in value_flags:
            skip = True
            continue
        if not item.startswith("-"):
            return item
    return None


def current_head_oid(head: str = "sync/upstream") -> str:
    configured = os.environ.get("GH_STUB_HEAD_REF_OID")
    if configured:
        return configured
    repository = os.environ.get("GH_STUB_GIT_REPO")
    if not repository:
        return ""
    result = subprocess.run(
        ["git", "-C", repository, "ls-remote", "origin", f"refs/heads/{head}"],
        capture_output=True,
        text=True,
        check=False,
    )
    fields = result.stdout.split()
    return fields[0] if fields else ""


def configured_labels() -> list[str]:
    value = os.environ.get("GH_STUB_REPO_LABELS_JSON")
    if value is not None:
        return json.loads(value)
    return os.environ.get("GH_STUB_REPO_LABELS", "upstream-conflict").split()


def initial_prs() -> list[dict[str, Any]]:
    configured = os.environ.get("GH_STUB_PRS_JSON")
    if configured is not None:
        records = json.loads(configured)
        if not isinstance(records, list):
            raise ValueError("GH_STUB_PRS_JSON must contain an array")
        return records
    state = os.environ.get("GH_STUB_STATE", "NONE")
    if state == "NONE":
        return []
    numbers = [
        int(item)
        for item in os.environ.get("GH_STUB_OPEN_PR_NUMBERS", "5").split(",")
        if item
    ]
    comments = json.loads(
        os.environ.get("GH_STUB_COMMENTS_JSON", '{"comments":[]}')
    ).get("comments", [])
    return [
        {
            "number": number,
            "state": state,
            "baseRefName": os.environ.get("GH_STUB_BASE_REF_NAME", "main"),
            "headRefName": os.environ.get("GH_STUB_HEAD_REF_NAME", "sync/upstream"),
            "headRefOid": current_head_oid(),
            "headRepository": os.environ.get(
                "GH_STUB_HEAD_REPOSITORY", "LMLiam/freebuffed"
            ),
            "isDraft": os.environ.get("GH_STUB_DRAFT", "false") == "true",
            "labels": os.environ.get("GH_STUB_LABELS", "").split(),
            "title": "",
            "comments": comments,
        }
        for number in numbers
    ]


def normalise_pr(pr: dict[str, Any]) -> dict[str, Any]:
    record = dict(pr)
    record.setdefault("baseRefName", "main")
    record.setdefault("headRefName", "sync/upstream")
    record.setdefault("headRefOid", current_head_oid(record["headRefName"]))
    record.setdefault("headRepository", "LMLiam/freebuffed")
    record.setdefault("isDraft", False)
    record.setdefault("labels", [])
    record.setdefault("title", "")
    record.setdefault("comments", [])
    return record


def gh_pr(pr: dict[str, Any], fields: list[str] | None = None) -> dict[str, Any]:
    record = {
        "number": pr["number"],
        "state": pr["state"],
        "baseRefName": pr["baseRefName"],
        "headRefName": pr["headRefName"],
        "headRefOid": pr["headRefOid"],
        "headRepository": {"nameWithOwner": pr["headRepository"]},
        "isDraft": pr["isDraft"],
        "labels": [{"name": name} for name in pr["labels"]],
        "title": pr["title"],
        "comments": [
            {"id": comment["id"], "body": comment["body"]}
            for comment in pr["comments"]
        ],
    }
    if fields is None:
        return record
    return {field: record[field] for field in fields}


def find_pr(prs: list[dict[str, Any]], value: str | None) -> dict[str, Any] | None:
    if value is None:
        return None
    if value.isdigit():
        return next((pr for pr in prs if pr["number"] == int(value)), None)
    matches = [pr for pr in prs if pr["headRefName"] == value]
    open_matches = [pr for pr in matches if pr["state"] == "OPEN"]
    selected = open_matches or matches
    return max(selected, key=lambda pr: pr["number"]) if selected else None


args = sys.argv[1:]
command_line = " ".join(args)
with open(os.environ["GH_STUB_LOG"], "a", encoding="utf-8") as log:
    log.write(f"gh {command_line}\n")
for pattern in os.environ.get("GH_STUB_FAIL", "").split(","):
    if pattern and fnmatch.fnmatch(command_line, pattern):
        sys.exit(1)

state_file = os.environ["GH_STUB_STATE_FILE"]
if os.path.exists(state_file):
    with open(state_file, encoding="utf-8") as handle:
        state = json.load(handle)
else:
    prs = [normalise_pr(pr) for pr in initial_prs()]
    max_pr = max((pr["number"] for pr in prs), default=4)
    max_comment = max(
        (
            comment.get("rest_id", 99)
            for pr in prs
            for comment in pr.get("comments", [])
        ),
        default=99,
    )
    state = {
        "prs": prs,
        "repo_labels": configured_labels(),
        "next_pr_number": max_pr + 1,
        "next_comment_id": max_comment + 1,
    }

prs = state["prs"]
if not os.environ.get("GH_STUB_HEAD_REF_OID"):
    for pull_request in prs:
        if pull_request["state"] == "OPEN":
            live_oid = current_head_oid(pull_request["headRefName"])
            if live_oid:
                pull_request["headRefOid"] = live_oid

if args[0] == "api":
    if len(args) > 1 and args[1] == "user":
        user = {"login": os.environ.get("GH_STUB_LOGIN", "freebuffed[bot]")}
        print(user["login"] if "--jq" in args else json.dumps(user))
    elif "-X" in args and "PATCH" in args:
        match = re.search(r"issues/comments/(\d+)", command_line)
        body = arg_value(args, "-f")
        body = body.split("=", 1)[1] if body and body.startswith("body=") else None
        if match is None:
            sys.exit(1)
        for pr in prs:
            for comment in pr["comments"]:
                if comment["rest_id"] == int(match.group(1)):
                    if body is not None:
                        comment["body"] = body
                    break
            else:
                continue
            break
        else:
            sys.exit(1)
    else:
        url = next((item for item in args if item.startswith("repos/")), "")
        if url.endswith("/labels"):
            if int(os.environ.get("GH_STUB_HTTP_STATUS", "200")) >= 400:
                sys.exit(1)
            values = [{"name": name} for name in state["repo_labels"]]
            if "--jq" in args:
                print("\n".join(state["repo_labels"]))
            else:
                print(json.dumps(values))
        else:
            match = re.search(r"issues/(\d+)/comments", url)
            if match is None:
                sys.exit(1)
            pr = find_pr(prs, match.group(1))
            if pr is None:
                sys.exit(1)
            comments = [
                {
                    "id": comment["rest_id"],
                    "node_id": comment["id"],
                    "user": comment.get("user", {}),
                    "body": comment["body"],
                }
                for comment in pr["comments"]
            ]
            if "--jq" in args:
                for comment in comments:
                    if "sync-conflict-notice" in comment["body"]:
                        print(comment["id"])
            else:
                print(json.dumps(comments))

elif args[0] == "pr":
    subcommand = args[1] if len(args) > 1 else ""
    if subcommand == "list":
        requested_state = arg_value(args, "--state") or "open"
        requested_head = arg_value(args, "--head")
        requested_base = arg_value(args, "--base")
        selected = [
            pr
            for pr in prs
            if (requested_state == "all" or pr["state"] == requested_state.upper())
            and (requested_head is None or pr["headRefName"] == requested_head)
            and (requested_base is None or pr["baseRefName"] == requested_base)
        ]
        selected.sort(key=lambda pr: pr["number"], reverse=True)
        fields_value = arg_value(args, "--json")
        fields = fields_value.split(",") if fields_value else None
        records = [gh_pr(pr, fields) for pr in selected]
        if "--jq" in args:
            if ".[].number" in command_line:
                print("\n".join(str(record["number"]) for record in records))
            elif "@tsv" in command_line:
                for record in records:
                    print("\t".join(str(record[field]) for field in fields or []))
        else:
            print(json.dumps(records))
    elif subcommand == "view":
        pr = find_pr(prs, selector(args))
        if pr is None:
            sys.exit(1)
        fields_value = arg_value(args, "--json")
        fields = fields_value.split(",") if fields_value else None
        record = gh_pr(pr, fields)
        if "--jq" not in args:
            print(json.dumps(record))
        elif "labels" in (fields or []):
            print("\n".join(pr["labels"]))
        elif "isDraft" in (fields or []):
            print("true" if pr["isDraft"] else "false")
        elif "title" in (fields or []):
            print(pr["title"])
        elif "comments" in (fields or []):
            for comment in pr["comments"]:
                if "sync-conflict-notice" in comment["body"]:
                    print(comment["id"])
        elif "number" in (fields or []):
            print(pr["number"])
        elif "state" in (fields or []):
            print(pr["state"])
    elif subcommand == "create":
        number = state["next_pr_number"]
        state["next_pr_number"] += 1
        head = arg_value(args, "--head") or "sync/upstream"
        prs.append(
            normalise_pr(
                {
                    "number": number,
                    "state": "OPEN",
                    "baseRefName": arg_value(args, "--base") or "main",
                    "headRefName": head,
                    "headRefOid": current_head_oid(head),
                    "headRepository": os.environ.get(
                        "GH_STUB_HEAD_REPOSITORY", "LMLiam/freebuffed"
                    ),
                    "isDraft": "--draft" in args,
                    "labels": [],
                    "title": arg_value(args, "--title") or "",
                    "comments": [],
                }
            )
        )
        print(f"https://github.test/pull/{number}")
    elif subcommand == "edit":
        pr = find_pr(prs, selector(args))
        if pr is None:
            sys.exit(1)
        title = arg_value(args, "--title")
        if title is not None:
            pr["title"] = title
        label = arg_value(args, "--add-label")
        if label is not None and label not in pr["labels"]:
            pr["labels"].append(label)
        label = arg_value(args, "--remove-label")
        if label is not None and label in pr["labels"]:
            pr["labels"].remove(label)
    elif subcommand == "ready":
        pr = find_pr(prs, selector(args))
        if pr is None:
            sys.exit(1)
        pr["isDraft"] = "--undo" in args
    elif subcommand == "comment":
        pr = find_pr(prs, selector(args))
        if pr is None:
            sys.exit(1)
        rest_id = state["next_comment_id"]
        state["next_comment_id"] += 1
        pr["comments"].append(
            {
                "id": f"IC_kwDOT2TnS86Y{rest_id}",
                "rest_id": rest_id,
                "user": {"login": os.environ.get("GH_STUB_LOGIN", "freebuffed[bot]")},
                "body": arg_value(args, "--body") or "",
            }
        )

with open(state_file, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
