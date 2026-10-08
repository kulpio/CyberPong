#!/usr/bin/env python3
"""Contract tests for live orchestrator harness switch (pairs.json shape).

Swift implements Workers.switchConductorModel; this file locks the roster
mutation rules: only conductor type/cmd/label change; workers untouched;
invalid types refused.
"""

from __future__ import annotations

import copy
import unittest

ALLOWED_CONDUCTOR_TYPES = frozenset({"grok", "claude", "hermes"})


def apply_conductor_switch(
    entry: dict,
    new_type: str,
    *,
    cmd: str | None = None,
    label: str | None = None,
) -> dict | None:
    """Pure roster mutation mirroring Workers.switchConductorModel.

    Returns updated entry, or None if type is invalid.
    """
    tid = (new_type or "").strip().lower()
    if tid not in ALLOWED_CONDUCTOR_TYPES:
        return None
    out = copy.deepcopy(entry)
    cond = dict(out.get("conductor") or {})
    cmds = {"grok": "grok", "claude": "claude", "hermes": "hermes chat"}
    labels = {
        "grok": "Grok Build",
        "claude": "Claude Code",
        "hermes": "Hermes Agent",
    }
    cond["id"] = "c1"
    cond["type"] = tid
    cond["cmd"] = cmd if cmd is not None else cmds[tid]
    if label is not None:
        cond["label"] = label
    else:
        old_label = str(cond.get("label") or "").strip()
        old_type = str(cond.get("type") or "")
        # When still on previous type before assign — use new default if blank/auto
        if not old_label or old_label in labels.values():
            cond["label"] = labels[tid]
        else:
            cond["label"] = old_label
    cond["mode"] = cond.get("mode") or "tmux"
    cond["tmux_index"] = 0
    out["conductor"] = cond
    return out


class ConductorSwitchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.entry = {
            "schema_version": 2,
            "display_name": "CyberPong",
            "conductor": {
                "id": "c1",
                "type": "grok",
                "cmd": "grok",
                "label": "Grok Build",
                "mode": "tmux",
                "tmux_index": 0,
            },
            "workers": [
                {
                    "id": "w1",
                    "type": "claude",
                    "label": "Builder",
                    "mission_role": "coder",
                    "tmux_index": 1,
                },
                {
                    "id": "w2",
                    "type": "claude",
                    "label": "Checker",
                    "mission_role": "reviewer",
                    "tmux_index": 2,
                },
            ],
            "flow_graph": {"edges": [{"from": "c1", "to": "w1", "kind": "delegate"}]},
        }

    def test_refuse_invalid_type(self) -> None:
        self.assertIsNone(apply_conductor_switch(self.entry, "codex"))
        self.assertIsNone(apply_conductor_switch(self.entry, "custom"))
        self.assertIsNone(apply_conductor_switch(self.entry, ""))
        self.assertIsNone(apply_conductor_switch(self.entry, "GPT-4"))

    def test_updates_conductor_fields(self) -> None:
        out = apply_conductor_switch(self.entry, "hermes")
        assert out is not None
        c = out["conductor"]
        self.assertEqual(c["id"], "c1")
        self.assertEqual(c["type"], "hermes")
        self.assertEqual(c["cmd"], "hermes chat")
        self.assertEqual(c["label"], "Hermes Agent")
        self.assertEqual(c["tmux_index"], 0)
        self.assertEqual(c["mode"], "tmux")

    def test_workers_and_graph_untouched(self) -> None:
        out = apply_conductor_switch(self.entry, "claude")
        assert out is not None
        self.assertEqual(out["workers"], self.entry["workers"])
        self.assertEqual(out["flow_graph"], self.entry["flow_graph"])
        self.assertEqual(out["display_name"], "CyberPong")
        # Same worker ids and mission roles
        self.assertEqual(
            [w["mission_role"] for w in out["workers"]],
            ["coder", "reviewer"],
        )

    def test_claude_cmd(self) -> None:
        out = apply_conductor_switch(self.entry, "claude")
        assert out is not None
        self.assertEqual(out["conductor"]["cmd"], "claude")
        self.assertEqual(out["conductor"]["type"], "claude")

    def test_custom_label_preserved(self) -> None:
        self.entry["conductor"]["label"] = "Boss Bot"
        out = apply_conductor_switch(self.entry, "hermes")
        assert out is not None
        # Pure helper keeps non-catalog labels (Swift matches this intent)
        self.assertEqual(out["conductor"]["label"], "Boss Bot")
        self.assertEqual(out["conductor"]["type"], "hermes")


if __name__ == "__main__":
    unittest.main()
