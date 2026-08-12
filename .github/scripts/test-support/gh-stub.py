#!/usr/bin/env python3
"""Small gh CLI fake for the upstream-sync integration tests."""

import fnmatch
import json
import os
import re
import sys


def arg_value(args, flag):
    for index, item in enumerate(args):
        if item == flag and index + 1 < len(args):
            return args[index + 1]
    return None


def api_url(args):
    for item in args:
        if item.startswith("repos/"):
            return item
    return ""


def open_pr_numbers():
    configured = os.environ.get("GH_STUB_OPEN_PR_NUMBERS")
    if configured is not None:
        return [int(number) for number in configured.split(",") if number]
    return [int(os.environ.get("GH_STUB_PR_NUMBER", "5"))]


def configured_repo_labels():
    configured = os.environ.get("GH_STUB_REPO_LABELS_JSON")
    if configured is not None:
        return json.loads(configured)
    return os.environ.get("GH_STUB_REPO_LABELS", "upstream-conflict").split()


args = sys.argv[1:]
cmd_line = " ".join(args)
with open(os.environ["GH_STUB_LOG"], "a") as log:
    log.write("gh " + cmd_line + "\n")
for pattern in os.environ.get("GH_STUB_FAIL", "").split(","):
    if pattern and fnmatch.fnmatch(cmd_line, pattern):
        sys.exit(1)

state_file = os.environ["GH_STUB_STATE_FILE"]
if os.path.exists(state_file):
    with open(state_file) as handle:
        state = json.load(handle)
else:
    comments = json.loads(
        os.environ.get("GH_STUB_COMMENTS_JSON", '{"comments":[]}')
    ).get("comments", [])
    state = {
        "pr": {
            "state": os.environ.get("GH_STUB_STATE", "CLOSED"),
            "isDraft": os.environ.get("GH_STUB_DRAFT", "false") == "true",
            "labels": os.environ.get("GH_STUB_LABELS", "").split(),
            "title": "",
            "comments": comments,
        },
        "repo_labels": configured_repo_labels(),
        "next_comment_id": 100,
    }

if args[0] == "api":
    if len(args) > 1 and args[1] == "user":
        print(os.environ.get("GH_STUB_LOGIN", "freebuffed[bot]"))
    elif "-X" in args and "PATCH" in cmd_line:
        match = re.search(r"issues/comments/([^/\s]+)", cmd_line)
        body = None
        for item in args:
            if item.startswith("body="):
                body = item.split("=", 1)[1]
        if not match or not match.group(1).isdigit():
            sys.exit(1)
        for comment in state["pr"]["comments"]:
            if str(comment["rest_id"]) == match.group(1):
                if body is not None:
                    comment["body"] = body
                break
        else:
            sys.exit(1)
    else:
        url = api_url(args)
        if url.endswith("/labels"):
            status = int(os.environ.get("GH_STUB_HTTP_STATUS", "200"))
            if status >= 400:
                sys.exit(1)
            if "--jq" in args and ".[].name" in cmd_line:
                print("\n".join(state["repo_labels"]))
            else:
                print(json.dumps([{"name": name} for name in state["repo_labels"]]))
        else:
            comments_match = re.search(r"issues/(\d+)/comments", cmd_line)
            if comments_match:
                comments = [
                    {
                        "id": comment["rest_id"],
                        "node_id": comment["id"],
                        "user": comment.get("user", {}),
                        "body": comment["body"],
                    }
                    for comment in state["pr"]["comments"]
                ]
                if "--jq" in args and (
                    'contains("sync-conflict-notice")' in cmd_line
                    or "SYNC_CONFLICT_NOTICE_MARKER" in cmd_line
                ):
                    marker = os.environ.get(
                        "SYNC_CONFLICT_NOTICE_MARKER", "<!-- sync-conflict-notice -->"
                    )
                    login = os.environ.get(
                        "SYNC_AUTOMATION_LOGIN", os.environ.get("GH_STUB_LOGIN", "")
                    )
                    for comment in comments:
                        body = comment.get("body", "")
                        user = comment.get("user", {}).get("login")
                        if "SYNC_CONFLICT_NOTICE_MARKER" in cmd_line:
                            matches = body.split("\n", 1)[0] == marker and user == login
                        else:
                            matches = "sync-conflict-notice" in body
                        if matches:
                            print(comment["id"])
                else:
                    print(json.dumps(comments))

elif args[0] == "pr":
    sub = args[1] if len(args) > 1 else ""
    if sub == "view":
        if "--json labels" in cmd_line:
            print("\n".join(state["pr"]["labels"]))
        elif "--json isDraft" in cmd_line:
            print("true" if state["pr"]["isDraft"] else "false")
        elif "--json title" in cmd_line:
            print(state["pr"]["title"])
        elif "--json comments" in cmd_line:
            for comment in state["pr"]["comments"]:
                if "sync-conflict-notice" in comment.get("body", ""):
                    print(comment["id"])
        elif "--json number" in cmd_line:
            print(os.environ.get("GH_STUB_PR_NUMBER", "5"))
        elif "--json state" in cmd_line:
            print(state["pr"]["state"])
        else:
            print(json.dumps({"state": state["pr"]["state"]}))
    elif sub == "list":
        if state["pr"]["state"] == "OPEN":
            numbers = open_pr_numbers()
            if "--jq" in args:
                for number in numbers:
                    print(number)
            else:
                print(json.dumps([{"number": number} for number in numbers]))
        elif "--jq" not in args:
            print("[]")
    elif sub == "create":
        state["pr"]["state"] = "OPEN"
        state["pr"]["isDraft"] = "--draft" in args
        title = arg_value(args, "--title")
        if title is not None:
            state["pr"]["title"] = title
    elif sub == "edit":
        title = arg_value(args, "--title")
        if title is not None:
            state["pr"]["title"] = title
        label = arg_value(args, "--add-label")
        if label is not None and label not in state["pr"]["labels"]:
            state["pr"]["labels"].append(label)
        label = arg_value(args, "--remove-label")
        if label is not None and label in state["pr"]["labels"]:
            state["pr"]["labels"].remove(label)
    elif sub == "ready":
        state["pr"]["isDraft"] = "--undo" in args
    elif sub == "comment":
        rest_id = state["next_comment_id"]
        state["pr"]["comments"].append(
            {
                "id": f"IC_kwDOT2TnS86Y{rest_id}",
                "rest_id": rest_id,
                "user": {"login": os.environ.get("GH_STUB_LOGIN", "freebuffed[bot]")},
                "body": arg_value(args, "--body") or "",
            }
        )
        state["next_comment_id"] += 1

with open(state_file, "w") as handle:
    json.dump(state, handle)
