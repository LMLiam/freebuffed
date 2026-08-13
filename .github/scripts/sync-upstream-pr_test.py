#!/usr/bin/env python3
"""Test the typed GitHub pull-request contract."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import unittest


SCRIPT_DIR = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location(
    "sync_upstream_pr", SCRIPT_DIR / "sync-upstream-pr.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PullRequestContractTest(unittest.TestCase):
    def test_captured_pull_request_shape_parses(self) -> None:
        fixture = SCRIPT_DIR / "test-support/fixtures/gh-pr-view-open.json"
        pull_request = MODULE.parse_pull_request(json.loads(fixture.read_text()))

        self.assertEqual(5, pull_request.number)
        self.assertEqual("LMLiam/freebuffed", pull_request.head_repo)
        self.assertEqual("e35dc7d9f681ed6e8c23e42667799aa2ab34ebc1", pull_request.head_oid)
        self.assertEqual(("area: ci", "area: docs"), pull_request.labels)

    def test_empty_captured_list_is_valid_json(self) -> None:
        fixture = SCRIPT_DIR / "test-support/fixtures/gh-pr-list-empty.json"

        self.assertEqual([], MODULE.parse_json(fixture.read_text(), "fixture"))

    def test_old_merged_pr_does_not_match_new_tip(self) -> None:
        pull_request = MODULE.PullRequest(
            number=4,
            state="MERGED",
            base_ref="main",
            head_ref="sync/upstream",
            head_oid="a" * 40,
            head_repo="LMLiam/freebuffed",
        )

        result = MODULE.classify_pull_requests(
            [pull_request],
            "LMLiam/freebuffed",
            "main",
            "sync/upstream",
            "b" * 40,
        )

        self.assertEqual("ABSENT", result)

    def test_exact_merged_pr_head_is_selected(self) -> None:
        exact_pull_request = MODULE.PullRequest(
            number=4,
            state="MERGED",
            base_ref="main",
            head_ref="sync/upstream",
            head_oid="a" * 40,
            head_repo="LMLiam/freebuffed",
        )
        newer_pull_request = MODULE.PullRequest(
            number=6,
            state="CLOSED",
            base_ref="main",
            head_ref="sync/upstream",
            head_oid="b" * 40,
            head_repo="LMLiam/freebuffed",
        )

        result = MODULE.classify_pull_requests(
            [newer_pull_request, exact_pull_request],
            "LMLiam/freebuffed",
            "main",
            "sync/upstream",
            "a" * 40,
        )

        self.assertEqual("MERGED\t4", result)

    def test_external_branch_name_collision_is_ignored(self) -> None:
        internal_pull_request = MODULE.PullRequest(
            number=4,
            state="MERGED",
            base_ref="main",
            head_ref="sync/upstream",
            head_oid="a" * 40,
            head_repo="LMLiam/freebuffed",
        )
        external_pull_request = MODULE.PullRequest(
            number=7,
            state="OPEN",
            base_ref="main",
            head_ref="sync/upstream",
            head_oid="b" * 40,
            head_repo="external/freebuffed",
        )

        result = MODULE.classify_pull_requests(
            [external_pull_request, internal_pull_request],
            "LMLiam/freebuffed",
            "main",
            "sync/upstream",
            "a" * 40,
        )

        self.assertEqual("MERGED\t4", result)


if __name__ == "__main__":
    unittest.main()
