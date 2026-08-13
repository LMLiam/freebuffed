#!/usr/bin/env python3
"""Classify and reconcile the upstream sync pull request."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Sequence


CONFLICT_NOTICE_MARKER = "<!-- sync-conflict-notice -->"
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


class SyncPrError(Exception):
    """Report a safe synchronization failure."""


@dataclass(frozen=True)
class PullRequest:
    """Store the GitHub fields that define one sync pull request."""

    number: int
    state: str
    base_ref: str
    head_ref: str
    head_oid: str
    head_repo: str
    is_draft: bool = False
    labels: tuple[str, ...] = ()
    title: str = ""


def error(message: str) -> None:
    """Write one GitHub Actions error annotation."""

    print(f"::error::{message}", file=sys.stderr)


def run_gh(arguments: Sequence[str], failure: str) -> str:
    """Run GitHub CLI and return stdout. Convert failures to a safe error."""

    result = subprocess.run(
        ["gh", *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SyncPrError(failure)
    return result.stdout


def parse_json_documents(value: str, description: str) -> list[Any]:
    """Parse one or more adjacent JSON documents from GitHub CLI output."""

    decoder = json.JSONDecoder()
    documents: list[Any] = []
    offset = 0
    try:
        while offset < len(value):
            while offset < len(value) and value[offset].isspace():
                offset += 1
            if offset == len(value):
                break
            document, offset = decoder.raw_decode(value, offset)
            documents.append(document)
    except json.JSONDecodeError as exception:
        raise SyncPrError(f"could not parse {description}") from exception
    return documents


def parse_json(value: str, description: str) -> Any:
    """Parse exactly one JSON document."""

    documents = parse_json_documents(value, description)
    if len(documents) != 1:
        raise SyncPrError(f"could not parse {description}")
    return documents[0]


def require_string(record: dict[str, Any], field: str) -> str:
    value = record.get(field)
    if not isinstance(value, str):
        raise SyncPrError(f"pull request field {field} has an invalid value")
    return value


def parse_pull_request(record: Any) -> PullRequest:
    """Validate one GitHub pull-request JSON record."""

    if not isinstance(record, dict):
        raise SyncPrError("pull request data has an invalid shape")
    number = record.get("number")
    is_draft = record.get("isDraft", False)
    labels_value = record.get("labels", [])
    repository = record.get("headRepository")
    if not isinstance(number, int) or number <= 0:
        raise SyncPrError("pull request number has an invalid value")
    if not isinstance(is_draft, bool):
        raise SyncPrError(f"pull request #{number} has an invalid draft state")
    if not isinstance(repository, dict) or not isinstance(
        repository.get("nameWithOwner"), str
    ):
        raise SyncPrError(f"pull request #{number} has no valid head repository")
    if not isinstance(labels_value, list):
        raise SyncPrError(f"pull request #{number} has invalid labels")
    labels: list[str] = []
    for label in labels_value:
        if not isinstance(label, dict) or not isinstance(label.get("name"), str):
            raise SyncPrError(f"pull request #{number} has invalid labels")
        labels.append(label["name"])
    state = require_string(record, "state")
    if state not in {"OPEN", "MERGED", "CLOSED"}:
        raise SyncPrError(f"pull request #{number} has unexpected state '{state}'")
    return PullRequest(
        number=number,
        state=state,
        base_ref=require_string(record, "baseRefName"),
        head_ref=require_string(record, "headRefName"),
        head_oid=require_string(record, "headRefOid"),
        head_repo=repository["nameWithOwner"],
        is_draft=is_draft,
        labels=tuple(labels),
        title=require_string(record, "title") if "title" in record else "",
    )


def read_pull_requests(
    repo: str, base: str, head: str, state: str = "all"
) -> list[PullRequest]:
    """Read and validate pull requests for one branch identity."""

    fields = (
        "number,state,headRefOid,baseRefName,headRefName,headRepository,"
        "isDraft,labels,title"
    )
    output = run_gh(
        [
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            state,
            "--head",
            head,
            "--base",
            base,
            "--json",
            fields,
        ],
        f"could not read pull requests for {head}; branch left unchanged",
    )
    records = parse_json(output, f"pull requests for {head}")
    if not isinstance(records, list):
        raise SyncPrError(f"pull request list for {head} has an invalid shape")
    return [parse_pull_request(record) for record in records]


def validate_identity(pr: PullRequest, repo: str, base: str, head: str) -> None:
    """Require the configured base, head, and repository identity."""

    if not has_identity(pr, repo, base, head):
        raise SyncPrError(
            f"pull request #{pr.number} does not target {base} from {repo}:{head}; "
            "branch left unchanged"
        )


def has_identity(pr: PullRequest, repo: str, base: str, head: str) -> bool:
    """Return true for the configured base, head, and repository identity."""

    return pr.base_ref == base and pr.head_ref == head and pr.head_repo == repo


def classify_pull_requests(
    pull_requests: Sequence[PullRequest], repo: str, base: str, head: str, tip: str
) -> str:
    """Classify validated records against one observed remote tip."""

    matching_pull_requests = [
        pr for pr in pull_requests if has_identity(pr, repo, base, head)
    ]
    open_pull_requests = [pr for pr in matching_pull_requests if pr.state == "OPEN"]
    if len(open_pull_requests) > 1:
        raise SyncPrError(f"found more than one open pull request for {head}")
    exact = [pr for pr in matching_pull_requests if pr.head_oid == tip]
    if len(exact) > 1:
        raise SyncPrError(f"more than one pull request matches {head} tip {tip}")
    if exact:
        return f"{exact[0].state}\t{exact[0].number}"
    if open_pull_requests:
        pr = open_pull_requests[0]
        raise SyncPrError(
            f"unmatched live branch {head}: remote tip {tip} does not match open "
            f"pull request #{pr.number} head {pr.head_oid}; branch left unchanged"
        )
    return "ABSENT"


def classify(repo: str, base: str, head: str, tip: str) -> str:
    """Read and classify the pull request for the observed remote tip."""

    return classify_pull_requests(
        read_pull_requests(repo, base, head), repo, base, head, tip
    )


def validate_label(label: str) -> None:
    """Reject label values that cannot be passed as one GitHub label."""

    if "," in label or any(
        ord(character) < 32 or ord(character) == 127 for character in label
    ):
        raise SyncPrError(
            "SYNC_CONFLICT_LABEL must not contain commas or control characters"
        )


def preflight(repo: str, label: str) -> None:
    """Require the configured conflict label before any Git mutation."""

    validate_label(label)
    output = run_gh(
        ["api", "--paginate", f"repos/{repo}/labels"],
        f"could not read labels from {repo}",
    )
    documents = parse_json_documents(output, f"labels from {repo}")
    labels: list[Any] = []
    for document in documents:
        if not isinstance(document, list):
            raise SyncPrError(f"label data from {repo} has an invalid shape")
        labels.extend(document)
    names = {
        item.get("name")
        for item in labels
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if label not in names:
        raise SyncPrError(
            f"label '{label}' does not exist. Create it once with: gh label create "
            f"'{label}' --color d73a4a --description 'Sync pull request has "
            "unresolved conflict markers'"
        )


def validate_version(version: str) -> None:
    """Require the three-part decimal version used by the upstream project."""

    if not VERSION_PATTERN.fullmatch(version):
        raise SyncPrError(
            f"upstream version '{version}' is invalid; expected MAJOR.MINOR.PATCH"
        )


def view_pull_request(number: int, repo: str) -> PullRequest:
    """Read one pull request by number."""

    fields = (
        "number,state,headRefOid,baseRefName,headRefName,headRepository,"
        "isDraft,labels,title"
    )
    output = run_gh(
        ["pr", "view", str(number), "--repo", repo, "--json", fields],
        f"could not read pull request #{number}",
    )
    return parse_pull_request(parse_json(output, f"pull request #{number}"))


def find_open_pull_request(
    repo: str, base: str, head: str, tip: str
) -> PullRequest | None:
    """Return the one open pull request for the exact candidate tip."""

    pull_requests = [
        pr
        for pr in read_pull_requests(repo, base, head, "open")
        if has_identity(pr, repo, base, head)
    ]
    if len(pull_requests) > 1:
        raise SyncPrError(f"found more than one open pull request for {head}")
    if not pull_requests:
        return None
    pr = pull_requests[0]
    if pr.head_oid != tip:
        raise SyncPrError(
            f"open pull request #{pr.number} head changed before reconciliation"
        )
    return pr


def create_pull_request(
    repo: str, base: str, head: str, title: str, conflicted: bool
) -> None:
    """Create one pull request for the prepared branch."""

    with tempfile.NamedTemporaryFile("w", encoding="utf-8") as body_file:
        body_file.write(
            "Automated sync from the [Freebuff upstream mirror]"
            "(https://github.com/CodebuffAI/freebuff).\n"
        )
        body_file.flush()
        arguments = ["pr", "create"]
        if conflicted:
            arguments.append("--draft")
        arguments.extend([
            "--repo",
            repo,
            "--base",
            base,
            "--head",
            head,
            "--title",
            title,
            "--body-file",
            body_file.name,
        ])
        run_gh(arguments, f"could not create the pull request for {head}")


def ensure_title(pr: PullRequest, repo: str, title: str) -> None:
    """Update the pull-request title only when it differs."""

    if pr.title == title:
        return
    run_gh(
        ["pr", "edit", str(pr.number), "--repo", repo, "--title", title],
        f"could not update title for pull request #{pr.number}",
    )


def read_owned_notice_id(repo: str, pr_number: int) -> int | None:
    """Return the one owned notice ID. Reject duplicate owned notices."""

    user_output = run_gh(
        ["api", "user"], "could not read the authenticated GitHub account"
    )
    user = parse_json(user_output, "authenticated GitHub account")
    if not isinstance(user, dict) or not isinstance(user.get("login"), str):
        raise SyncPrError("could not read the authenticated GitHub account")
    comments_output = run_gh(
        ["api", "--paginate", f"repos/{repo}/issues/{pr_number}/comments"],
        f"could not read comments for pull request #{pr_number}",
    )
    documents = parse_json_documents(
        comments_output, f"comments for pull request #{pr_number}"
    )
    comments: list[Any] = []
    for document in documents:
        if not isinstance(document, list):
            raise SyncPrError(
                f"comment data for pull request #{pr_number} has an invalid shape"
            )
        comments.extend(document)
    owned: list[int] = []
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        author = comment.get("user")
        body = comment.get("body")
        comment_id = comment.get("id")
        first_line = body.split("\n", 1)[0] if isinstance(body, str) else None
        if (
            isinstance(author, dict)
            and author.get("login") == user["login"]
            and first_line == CONFLICT_NOTICE_MARKER
        ):
            if not isinstance(comment_id, int):
                raise SyncPrError("owned conflict notice has an invalid REST ID")
            owned.append(comment_id)
    if len(owned) > 1:
        raise SyncPrError(
            f"pull request #{pr_number} has more than one owned conflict notice; "
            "remove duplicate bot notices before retrying"
        )
    return owned[0] if owned else None


def escape_path(value: bytes) -> str:
    """Escape controls, DEL, and backslashes while preserving valid UTF-8."""

    decoded = value.decode("utf-8", "backslashreplace")
    escaped: list[str] = []
    for character in decoded:
        code = ord(character)
        if character == "\\":
            escaped.append("\\\\")
        elif code < 32 or code == 127:
            escaped.append(f"\\x{code:02X}")
        else:
            escaped.append(character)
    return "".join(escaped)


def format_conflict_files(conflicts: Sequence[bytes]) -> str:
    """Format escaped Git paths as Markdown bullets."""

    bullets: list[str] = []
    for conflict in conflicts:
        display = escape_path(conflict)
        fence = "`"
        while fence in display:
            fence += "`"
        if display.startswith(" ") and display.endswith(" "):
            display = f" {display} "
        bullets.append(f"- {fence}{display}{fence}")
    return "\n".join(bullets)


def update_notice(repo: str, pr_number: int, body: str) -> None:
    """Update the owned notice or create it when it does not exist."""

    notice_id = read_owned_notice_id(repo, pr_number)
    if notice_id is None:
        run_gh(
            ["pr", "comment", str(pr_number), "--repo", repo, "--body", body],
            f"could not create the conflict notice for pull request #{pr_number}",
        )
        return
    run_gh(
        [
            "api",
            "-X",
            "PATCH",
            f"repos/{repo}/issues/comments/{notice_id}",
            "-f",
            f"body={body}",
        ],
        f"could not update the conflict notice for pull request #{pr_number}",
    )


def reconcile_conflicted(
    pr: PullRequest, repo: str, label: str, conflicts: Sequence[bytes]
) -> None:
    """Apply the draft, label, and notice state for a conflicted candidate."""

    if not pr.is_draft:
        run_gh(
            ["pr", "ready", "--undo", str(pr.number), "--repo", repo],
            f"could not convert pull request #{pr.number} to draft",
        )
    if label not in pr.labels:
        run_gh(
            ["pr", "edit", str(pr.number), "--repo", repo, "--add-label", label],
            f"could not add label '{label}' to pull request #{pr.number}",
        )
    body = (
        f"{CONFLICT_NOTICE_MARKER}\n"
        "⚠️ Sync has conflicts in:\n"
        f"{format_conflict_files(conflicts)}\n"
        "The pull request is a draft and stays a draft until the conflicts are resolved.\n"
    )
    update_notice(repo, pr.number, body)


def reconcile_resolved(pr: PullRequest, repo: str, label: str) -> None:
    """Remove only conflict state that the automation owns."""

    if label not in pr.labels:
        return
    if pr.is_draft:
        run_gh(
            ["pr", "ready", str(pr.number), "--repo", repo],
            f"could not mark pull request #{pr.number} ready for review",
        )
    notice_id = read_owned_notice_id(repo, pr.number)
    if notice_id is not None:
        body = (
            f"{CONFLICT_NOTICE_MARKER}\n"
            "✔️ Sync conflicts are resolved and the pull request is ready for review.\n"
        )
        run_gh(
            [
                "api",
                "-X",
                "PATCH",
                f"repos/{repo}/issues/comments/{notice_id}",
                "-f",
                f"body={body}",
            ],
            f"could not update the resolved notice for pull request #{pr.number}",
        )
    run_gh(
        ["pr", "edit", str(pr.number), "--repo", repo, "--remove-label", label],
        f"could not remove label '{label}' from pull request #{pr.number}",
    )


def read_conflicts(path: Path) -> list[bytes]:
    """Read one NUL-delimited conflict-path file."""

    value = path.read_bytes()
    return [item for item in value.split(b"\0") if item]


def reconcile(
    repo: str,
    base: str,
    head: str,
    tip: str,
    version: str,
    label: str,
    conflicts_path: Path,
    pr_number: int | None,
) -> None:
    """Create or update the pull request for one immutable candidate tip."""

    validate_version(version)
    validate_label(label)
    conflicts = read_conflicts(conflicts_path)
    pr: PullRequest | None
    if pr_number is None:
        pr = find_open_pull_request(repo, base, head, tip)
    else:
        pr = view_pull_request(pr_number, repo)
        validate_identity(pr, repo, base, head)
        if pr.state != "OPEN" or pr.head_oid != tip:
            raise SyncPrError(
                f"pull request #{pr.number} no longer matches {head} tip {tip}"
            )
    title = f"chore(upstream): sync freebuff {version}"
    if pr is None:
        create_pull_request(repo, base, head, title, bool(conflicts))
        pr = find_open_pull_request(repo, base, head, tip)
        if pr is None:
            raise SyncPrError(f"could not find the pull request created for {head}")
    ensure_title(pr, repo, title)
    pr = view_pull_request(pr.number, repo)
    validate_identity(pr, repo, base, head)
    if pr.state != "OPEN" or pr.head_oid != tip:
        raise SyncPrError(
            f"pull request #{pr.number} changed before reconciliation"
        )
    if conflicts:
        reconcile_conflicted(pr, repo, label, conflicts)
    else:
        reconcile_resolved(pr, repo, label)


def build_parser() -> argparse.ArgumentParser:
    """Create the command-line parser."""

    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    preflight_parser = commands.add_parser("preflight")
    preflight_parser.add_argument("--repo", required=True)
    preflight_parser.add_argument("--label", required=True)

    classify_parser = commands.add_parser("classify")
    classify_parser.add_argument("--repo", required=True)
    classify_parser.add_argument("--base", required=True)
    classify_parser.add_argument("--head", required=True)
    classify_parser.add_argument("--tip", required=True)

    reconcile_parser = commands.add_parser("reconcile")
    reconcile_parser.add_argument("--repo", required=True)
    reconcile_parser.add_argument("--base", required=True)
    reconcile_parser.add_argument("--head", required=True)
    reconcile_parser.add_argument("--tip", required=True)
    reconcile_parser.add_argument("--version", required=True)
    reconcile_parser.add_argument("--label", required=True)
    reconcile_parser.add_argument("--conflicts0", type=Path, required=True)
    reconcile_parser.add_argument("--pr-number", type=int)
    return parser


def main() -> int:
    """Run one GitHub synchronization command."""

    arguments = build_parser().parse_args()
    try:
        if arguments.command == "preflight":
            preflight(arguments.repo, arguments.label)
        elif arguments.command == "classify":
            print(classify(arguments.repo, arguments.base, arguments.head, arguments.tip))
        elif arguments.command == "reconcile":
            reconcile(
                arguments.repo,
                arguments.base,
                arguments.head,
                arguments.tip,
                arguments.version,
                arguments.label,
                arguments.conflicts0,
                arguments.pr_number,
            )
        return 0
    except (OSError, SyncPrError) as exception:
        error(str(exception))
        return 1


if __name__ == "__main__":
    sys.exit(main())
