#!/usr/bin/env python3
"""Synthetic, offline contracts for the report-only description trial."""

import concurrent.futures
import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "modules/home-manager/programs/ai/description-format.py"
SPEC = importlib.util.spec_from_file_location("description_format", SCRIPT)
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)

ISSUE = """**Status:** Ready for a synthetic trial.

**Next:** Run the offline checks.

**Owner:** Example maintainer.

**Why:** Keep descriptions readable.

**Plan:**
1. Add a fixture.
2. Check the result.

**Done when:**
- [ ] The fixture passes.
- [x] No network is used.
"""
PR = """**What:** Add a synthetic example.

**Why:** Exercise formatting. Part of #12.

**Risk:** Small local change.

**Verification:** Offline checks passed.

**After merge:** Review the observation results.
"""
TARGET = "git.example.test/example/project"
GH_TARGET = "github.com/example/project"
MARKER = "BODY-AND-COMMAND-MUST-STAY-PRIVATE"


def payload(operation="create_issue", body=ISSUE):
    args = {"owner": "example", "repo": "project"}
    if body is not None:
        args["body"] = body
    return {"tool_name": "mcp__forgejo__" + operation, "tool_input": args}


def bash(command, *, executor=False, cwd=None):
    data = {"tool_name": "exec_command" if executor else "Bash",
            "tool_input": {"cmd" if executor else "command": command}}
    if cwd:
        data["cwd"] = str(cwd)
    return data


def single_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


class ValidatorTests(unittest.TestCase):
    def rules(self, body, kind="issue"):
        return {d["rule"] for d in observer.validate(body, kind)}

    def test_valid_openings_and_leading_comments(self):
        for kind, body in (("issue", ISSUE), ("pr", PR)):
            with self.subTest(kind=kind):
                self.assertEqual(observer.validate("\n<!-- template\n# ignored\n-->\n\n" + body, kind), [])

    def test_order_missing_extra_and_empty_opening_labels(self):
        examples = [
            ISSUE.replace("**Status:**", "**Status update:**"),
            ISSUE.replace("**Next:** Run the offline checks.\n\n", ""),
            ISSUE.replace("**Next:**", "**Extra:** Stop here.\n\n**Next:**"),
            "A preamble.\n\n" + ISSUE,
            ISSUE.replace("**Status:** Ready for a synthetic trial.", "**Status:** <!-- empty -->"),
            PR.replace("**After merge:** Review the observation results.", "**After merge:**\n\n<details>\n<summary>Extra</summary>\n\nText\n</details>"),
        ]
        for body in examples:
            with self.subTest(body=body[:50]):
                self.assertTrue(observer.validate(body, "pr" if "**What:**" in body else "issue"))

    def test_list_quote_and_indented_labels_are_invalid(self):
        for prefix in ("- ", "> ", " ", "    ", "1. "):
            with self.subTest(prefix=prefix):
                self.assertTrue(observer.validate(ISSUE.replace("**Status:**", prefix + "**Status:**"), "issue"))

    def test_misplaced_required_label_below_opening(self):
        for suffix in ("\n**Status:** Again.\n", "\n- **Owner:** Elsewhere.\n", "\n> **Why:** Quoted.\n"):
            with self.subTest(suffix=suffix):
                self.assertIn("label-position", self.rules(ISSUE + suffix))

    def test_supporting_details_may_reuse_labels_without_supplying_openings(self):
        evidence = "\n<details>\n<summary>Source evidence</summary>\n\n**Status:** Historical context.\n\n<details>\n<summary>Nested evidence</summary>\n\n**Owner:** Historical owner.\n</details>\n</details>\n"
        self.assertEqual(observer.validate(ISSUE + evidence, "issue"), [])
        self.assertEqual(observer.validate(PR + "\n**Status:** Supporting context.\n", "pr"), [])
        self.assertTrue(observer.validate("<details>\n<summary>Hidden</summary>\n\n" + ISSUE + "\n</details>", "issue"))
        self.assertIn("label-position", self.rules(ISSUE + evidence + "\n**Status:** Duplicate visible block.\n"))
        self.assertIn("label-position", self.rules(ISSUE + evidence.replace("**Owner:**", "- **Owner:**")))

    def test_paragraph_separation(self):
        self.assertIn("paragraph-separation", self.rules(ISSUE.replace("\n\n**Next:", "\n**Next:")))

    def test_numbered_plan_and_checklist(self):
        for replacement in ("2. Add a fixture.", "- Add a fixture.", "Add a fixture."):
            with self.subTest(replacement=replacement):
                self.assertIn("plan-numbered", self.rules(ISSUE.replace("1. Add a fixture.", replacement)))
        self.assertIn("plan-numbered", self.rules(ISSUE.replace("2. Check the result.", "A separate paragraph.")))
        self.assertIn("done-checklist", self.rules(ISSUE.replace("- [ ] The fixture passes.", "- The fixture passes.")))
        self.assertIn("done-checklist", self.rules(ISSUE.replace("- [x] No network is used.", "A separate paragraph.")))

    def test_verification_is_one_line(self):
        self.assertIn("verification-line", self.rules(PR.replace("Offline checks passed.", "Offline checks passed.\nA second line."), "pr"))
        self.assertNotIn("verification-line", self.rules(PR.replace("Offline checks passed.", "`python3 check.py` passed."), "pr"))

    def test_verification_rejects_extra_literal_blocks_but_ignores_comments(self):
        for literal in ("```sh\npython3 check.py\n```", "~~~\nchecks passed\n~~~",
                        "    python3 check.py\n    checks passed", "\tpython3 check.py"):
            with self.subTest(literal=literal):
                body = PR.replace("Offline checks passed.", "Offline checks passed.\n\n" + literal)
                diagnostics = observer.validate(body, "pr")
                self.assertEqual([d["rule"] for d in diagnostics], ["verification-line"])
                self.assertEqual(diagnostics[0]["line"], 7)
                self.assertEqual(observer.validate(PR + "\n" + literal, "pr"), [])
        comment = "\n<!--\n```\n# commented example\n```\n-->\n<!-- comment -->"
        self.assertEqual(observer.validate(PR.replace("Offline checks passed.", "Offline checks passed." + comment), "pr"), [])

    def test_headings_inside_details_and_setext(self):
        for heading in ("# Heading", "###### Heading", "Heading\n-------", "Heading\n=======", "> ## Heading", "- ### Heading"):
            with self.subTest(heading=heading):
                body = PR + "\n<details>\n<summary>Evidence</summary>\n\n" + heading + "\n</details>"
                self.assertIn("markdown-heading", self.rules(body, "pr"))

    def test_summary_requires_blank_line_even_before_literal_code(self):
        for following in ("Text", "```\n# sample\n```", "    # sample"):
            with self.subTest(following=following):
                self.assertIn("summary-spacing", self.rules(PR + "\n<details>\n<summary>Evidence</summary>\n" + following, "pr"))

    def test_fences_match_character_and_minimum_length(self):
        body = PR + "\n````markdown\n# sample\n```\n**What:** sample\n~~~\n# sample\n`````\n"
        self.assertEqual(observer.validate(body, "pr"), [])
        self.assertIn("markdown-heading", self.rules(body + "\n# Outside\n", "pr"))
        self.assertEqual(observer.validate(PR + "\n~~~\n```\n# sample\n~~~\n", "pr"), [])
        self.assertEqual(observer.validate(PR + "\n```\n    ```\n# still literal\n```\n", "pr"), [])

    def test_comments_code_tables_links_and_hashtags_are_not_declarations(self):
        examples = """
<!--
# heading
**What:** sample
-->

    # literal code
    **What:** sample

`**Why:** inline` and a [link](https://example.test/#heading).

| Example | Value |
| --- | --- |
| **What:** | # token |

#hashtag

---

<details>
<summary>Evidence</summary>

**Background:** More context.
</details>
"""
        self.assertEqual(observer.validate(PR + examples, "pr"), [])
        self.assertEqual(observer.validate(PR.replace("Small local change.", "`<!--` is literal."), "pr"), [])
        self.assertEqual(observer.validate(PR + "\n```html <!--\n# code\n```\n", "pr"), [])
        self.assertIn("markdown-heading", self.rules(PR + "\n<!-- comment `-->`\n# outside\n", "pr"))

    def test_long_inline_delimiters_are_scanned_without_backtracking(self):
        body = PR + "\nLiteral " + "`" * 100000 + " text\n"
        self.assertEqual(observer.validate(body, "pr"), [])

    def test_values_may_continue_or_use_literal_code(self):
        body = ISSUE.replace("Ready for a synthetic trial.", "\nReady for a synthetic trial.")
        self.assertEqual(observer.validate(body, "issue"), [])
        self.assertEqual(observer.validate(PR.replace("Small local change.", "`none`"), "pr"), [])

    def test_diagnostics_are_capped_fixed_hints_and_source_lines(self):
        body = PR + "\n" + "\n".join("# " + MARKER for _ in range(50))
        diagnostics = observer.validate(body, "pr")
        self.assertEqual(len(diagnostics), 5)
        self.assertEqual(diagnostics[0]["line"], len(PR.splitlines()) + 2)
        self.assertNotIn(MARKER, json.dumps(diagnostics))
        for diagnostic in diagnostics:
            self.assertEqual(set(diagnostic), {"rule", "line", "hint"})

    def test_oversized_body_is_bounded(self):
        diagnostics = observer.validate("é" * observer.MAX_BODY, "issue")
        self.assertEqual([d["rule"] for d in diagnostics], ["input-limit"])


class HookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.state = self.root / "state"
        self.config_path = self.root / "config.json"
        self.config = {
            "schema": 1, "mode": "observe", "forgejo_host": "git.example.test",
            "repositories": {TARGET: {"issue": True, "pr": True}, GH_TARGET: {"issue": True, "pr": True}},
            "end_at": observer.timestamp(observer.utc_now() + dt.timedelta(days=1)),
            "state_dir": str(self.state),
        }
        self.save_config()

    def save_config(self):
        self.config_path.write_text(json.dumps(self.config))

    def observe(self, data, *, config_path=None, delivery="direct"):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = observer.hook(str(config_path or self.config_path), io.StringIO(data if isinstance(data, str) else json.dumps(data)), delivery)
        self.assertEqual(code, 0)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("Traceback", errors.getvalue())
        self.assertNotIn(MARKER, errors.getvalue())
        return errors.getvalue()

    def events(self):
        if not self.state.exists():
            return []
        return [json.loads(line) for file in sorted(self.state.glob("events.jsonl*")) for line in file.read_text().splitlines()]

    def test_all_mcp_writes_and_safe_aliases(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("no subprocess expected")):
            for name, body in (("create_issue", ISSUE), ("update_issue", ISSUE),
                               ("create_pull_request", PR), ("update_pull_request", PR)):
                for prefix in ("mcp__forgejo__", "functions.mcp__forgejo__", "mcp_forgejo_"):
                    data = payload(name, body)
                    data["tool_name"] = prefix + name
                    self.observe(data)
        self.assertEqual(len(self.events()), 12)
        self.assertEqual({event["outcome"] for event in self.events()}, {"valid"})

    def test_missing_and_empty_create_and_empty_replacement_are_invalid(self):
        for name in ("create_issue", "create_pull_request"):
            self.observe(payload(name, None))
            self.observe(payload(name, ""))
        for name in ("update_issue", "update_pull_request"):
            self.observe(payload(name, ""))
        self.assertEqual([event["outcome"] for event in self.events()], ["invalid"] * 6)

    def test_metadata_unknown_unlisted_and_template_overrides_skip(self):
        self.config["repositories"][TARGET]["pr"] = False
        self.save_config()
        self.observe(payload("update_issue", None))
        self.observe(payload("create_pull_request", "# bad"))
        self.observe({"tool_name": MARKER, "tool_input": {"body": MARKER}})
        self.observe({"tool_name": "fake__mcp__forgejo__create_issue", "tool_input": {"body": MARKER}})
        data = payload(body=MARKER)
        data["tool_input"]["repo"] = "unlisted"
        self.observe(data)
        events = self.events()
        self.assertEqual([e["outcome"] for e in events], ["skip"] * 5)
        self.assertNotIn("target", events[-1])
        self.assertNotIn("kind", events[2])
        self.assertNotIn(MARKER, json.dumps(events))

    def test_literal_bash_and_exec_writes_include_issues_and_prs(self):
        for kind, body in (("issue", ISSUE), ("pr", PR)):
            for action in ("create", "edit"):
                for executor in (False, True):
                    item = " 12" if action == "edit" else ""
                    self.observe(bash(f"gh {kind} {action}{item} -R github.com/example/project --body {single_quote(body)}", executor=executor))
        self.assertEqual([e["outcome"] for e in self.events()], ["valid"] * 8)
        self.assertEqual({e["kind"] for e in self.events()}, {"issue", "pr"})

    def test_explicit_urls_and_attached_flags(self):
        self.observe(bash("gh pr edit https://github.com/example/project/pull/12 -b" + single_quote(PR)))
        self.observe(bash("gh issue create --repo=github.com/example/project --body=" + single_quote(ISSUE)))
        self.observe(bash("gh pr create -Rgithub.com/example/project -b" + single_quote(PR)))
        self.observe(bash("gh pr create --repo https://github.com/example/project -b" + single_quote(PR)))
        self.assertEqual([e["outcome"] for e in self.events()], ["valid"] * 4)

    def test_body_files_are_regular_bounded_and_relative_to_cwd(self):
        body_file = self.root / "body.md"
        body_file.write_text(PR)
        self.observe(bash("gh pr create -R github.com/example/project --body-file body.md", cwd=self.root))
        self.observe(bash("gh pr edit 12 --repo github.com/example/project -F" + str(body_file)))
        body_file.write_text("")
        self.observe(bash("gh pr edit 12 -R github.com/example/project -F " + str(body_file)))
        self.assertEqual([e["outcome"] for e in self.events()], ["valid", "valid", "invalid"])

    def test_missing_symlink_fifo_oversized_and_stdin_files_are_unsupported(self):
        regular = self.root / "body.md"
        regular.write_text(PR)
        link = self.root / "link.md"
        link.symlink_to(regular)
        fifo = self.root / "pipe"
        os.mkfifo(fifo)
        big = self.root / "big.md"
        big.write_bytes(b"x" * (observer.MAX_BODY + 1))
        for path in ("-", str(link), str(fifo), str(big), str(self.root / "missing.md")):
            self.observe(bash("gh pr create -R github.com/example/project -F " + single_quote(path)))
        self.assertEqual([e["outcome"] for e in self.events()], ["unsupported"] * 5)

    def test_dynamic_generated_interactive_and_compound_forms_are_unsupported(self):
        forms = [
            '--body "$BODY"', '--body "$(cat body.md)"', '--body `cat body.md`',
            "--body $'generated\\nbody'", "--body unquoted*", "--body x; touch never",
            "--body x | cat", "--body x\ntrue", "--body x > output", "--body 'unterminated",
            "--body-file <(printf body)", "--body-file -", "--fill", "--fill-first", "--editor",
            "--web", "--template default", "", "--body x --body-file body.md", "--unknown-flag value",
        ]
        for form in forms:
            with self.subTest(form=form):
                self.observe(bash("gh pr create -R github.com/example/project " + form))
        self.assertEqual([e["outcome"] for e in self.events()], ["unsupported"] * len(forms))

    def test_quotes_and_escaped_expansions_stay_literal(self):
        # Shell-sensitive characters in single quotes, and escaped double-quote
        # expansions, must not be confused with generated bodies.
        body = PR.replace("Add a synthetic example.", "Add '$HOME', $(literal), `code`, * and ;.")
        self.observe(bash("gh pr create -R github.com/example/project -b " + single_quote(body)))
        quoted = PR.replace("Add a synthetic example.", "Add \\$HOME and \\`code\\`.")
        self.observe(bash('gh pr create -R github.com/example/project --body "' + quoted + '"'))
        self.assertEqual([e["outcome"] for e in self.events()], ["valid", "valid"])

    def test_arbitrary_shell_unknown_subcommands_and_help_skip(self):
        for command in ("echo " + MARKER, "echo hi; gh pr create -R github.com/example/project -b bad",
                        "python3 opaque.py", "gh api repos/example/project/issues", "gh pr view 12",
                        "gh issue create --help -R github.com/example/project"):
            self.observe(bash(command))
        self.assertEqual([e["outcome"] for e in self.events()], ["skip"] * 6)
        self.assertEqual({e["route"] for e in self.events()}, {"unmatched"})

    def test_gh_metadata_only_and_explicit_empty_body(self):
        self.observe(bash("gh issue edit 12 -R github.com/example/project --title 'Changed title'"))
        self.observe(bash("gh pr edit 12 -R github.com/example/project --body ''"))
        self.assertEqual([e["outcome"] for e in self.events()], ["skip", "invalid"])

    def test_bare_edit_is_interactive_and_unsupported(self):
        self.observe(bash("gh issue edit 12 -R github.com/example/project"))
        self.observe(bash("gh pr edit https://github.com/example/project/pull/12"))
        self.assertEqual([e["outcome"] for e in self.events()], ["unsupported", "unsupported"])

    def test_unresolved_targets_never_read_git_environment_or_body(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("no subprocess")), \
                mock.patch.object(observer.os, "environ", {}), \
                mock.patch.object(observer.os, "getenv", side_effect=AssertionError("no environment")), \
                mock.patch.object(observer, "regular_text", wraps=observer.regular_text) as read, \
                mock.patch.object(observer, "validate", side_effect=AssertionError("no body validation")):
            for command in (
                    "gh pr create -b bad", "gh pr edit 12 --title changed",
                    "gh pr create -R example/project -F never-read.md",
                    "gh pr create -R github.com/example/project -R github.com/other/project -b bad",
                    "gh pr edit https://github.com/other/project/pull/12 -R github.com/example/project -b bad",
                    "gh pr create --repo=https://user:password@example.test/example/project -b bad",
                    "gh pr create --repo=https://example.test:bad/example/project -b bad"):
                self.observe(bash(command, cwd=self.root / "nonexistent"))
            self.assertEqual(read.call_count, 7)  # Config only, no repository/body reads.
            self.assertTrue(all(call.args[0] == str(self.config_path) for call in read.call_args_list))
        events = self.events()
        self.assertEqual([e["outcome"] for e in events], ["unsupported"] * 7)
        self.assertTrue(all("target" not in e for e in events))
        self.assertTrue(all(e["rules"] == [{"rule": "unsupported-target", "line": 1}] for e in events))
        summary = observer.report(str(self.state))
        self.assertEqual(summary["candidates"], 0)
        self.assertEqual(summary["outcomes"], {"unsupported": 7})

    def test_explicit_unlisted_targets_skip_without_body_validation(self):
        with mock.patch.object(observer, "validate", side_effect=AssertionError("no body validation")):
            self.assertEqual(self.observe(bash("gh pr create -R github.com/unlisted/project -b bad")), "")
        self.assertEqual(self.events()[0]["outcome"], "skip")
        self.assertNotIn("target", self.events()[0])

    def test_short_repo_under_ambient_host_does_not_attribute_github_target(self):
        with mock.patch.dict(os.environ, {"GH_HOST": "other.example.test", "GH_REPO": GH_TARGET}), \
                mock.patch.object(observer, "validate", side_effect=AssertionError("no body validation")):
            for selector in ("-R example/project", "--repo=example/project", "-Rexample/project"):
                self.observe(bash("gh pr create " + selector + " --body bad"))
        for event in self.events():
            self.assertEqual(event["outcome"], "unsupported")
            self.assertEqual(event["rules"], [{"rule": "unsupported-target", "line": 1}])
            self.assertNotIn("target", event)
        self.assertEqual(observer.report(str(self.state))["candidates"], 0)

    def test_linked_nix_config_is_supported(self):
        linked = self.root / "linked.json"
        linked.symlink_to(self.config_path)
        self.observe(payload(), config_path=linked)
        self.assertEqual(self.events()[0]["outcome"], "valid")

    def test_config_validation_is_pure_bounded_and_accepts_off_and_expired(self):
        def validate_config(expected):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                    mock.patch.object(subprocess, "Popen", side_effect=AssertionError("no subprocess")), \
                    mock.patch.object(observer, "append_event", side_effect=AssertionError("no state writes")):
                result = observer.main(["validate-config", "--config", str(self.config_path)])
            self.assertEqual(result, expected)
            self.assertEqual(out.getvalue(), "")
            self.assertEqual(err.getvalue(), "description-format: invalid or missing configuration.\n" if expected else "")
            self.assertFalse(self.state.exists())

        validate_config(0)
        self.config["mode"] = "off"
        self.config["end_at"] = None
        self.save_config()
        validate_config(0)
        self.assertEqual(self.observe("not JSON"), "")
        self.config["mode"] = "observe"
        self.config["end_at"] = "2000-01-01T00:00:00Z"
        self.save_config()
        validate_config(0)
        invalid_configs = [
            "{", "[]", MARKER, "x" * (observer.MAX_CONFIG + 1),
            json.dumps({**self.config, "mode": MARKER}),
            json.dumps({**self.config, "schema": True}),
            json.dumps({**self.config, "end_at": MARKER}),
            json.dumps({**self.config, "state_dir": MARKER}),
            json.dumps({**self.config, "forgejo_host": MARKER + "/bad"}),
            json.dumps({**self.config, "repositories": {TARGET: {"issue": MARKER}}}),
            json.dumps({**self.config, "repositories": {"example/project": {"pr": True}}}),
            json.dumps({k: v for k, v in self.config.items() if k != "forgejo_host"}),
        ]
        for config in invalid_configs:
            with self.subTest(config=config[:60]):
                self.config_path.write_text(config)
                validate_config(1)
        self.config_path.unlink()
        validate_config(1)
        os.mkfifo(self.config_path)
        validate_config(1)

    def test_delivery_attribution_and_per_delivery_outcomes(self):
        with mock.patch.object(observer, "managed_observer_available", return_value=False):
            for delivery in observer.DELIVERIES:
                self.observe(payload(), delivery=delivery)
                self.observe(payload(body=MARKER), delivery=delivery)
        self.assertEqual([e["delivery"] for e in self.events()],
                         [delivery for delivery in observer.DELIVERIES for _ in range(2)])
        summary = observer.report(str(self.state))
        self.assertEqual(summary["attempts"], 8)
        self.assertEqual(summary["deliveries"], dict.fromkeys(observer.DELIVERIES, 2))
        self.assertEqual(summary["delivery_outcomes"],
                         {delivery: {"valid": 1, "invalid": 1} for delivery in observer.DELIVERIES})

    def test_delivery_cli_forwards_both_flag_orders_and_config_cli_checks_files(self):
        for args in (("--config", str(self.config_path), "--delivery", "claude-user"),
                     ("--delivery", "codex-managed", "--config", str(self.config_path))):
            result = subprocess.run([sys.executable, str(SCRIPT), "hook", *args],
                                    input=json.dumps(payload()), text=True, capture_output=True, timeout=5)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual([e["delivery"] for e in self.events()], ["claude-user", "codex-managed"])
        for path, expected in ((self.config_path, 0), (self.root / MARKER, 1)):
            result = subprocess.run([sys.executable, str(SCRIPT), "validate-config", "--config", str(path)],
                                    text=True, capture_output=True, timeout=5)
            self.assertEqual((result.returncode, result.stdout), (expected, ""))
            self.assertEqual(result.stderr, "description-format: invalid or missing configuration.\n" if expected else "")

    def test_codex_user_duplicate_is_suppressed_only_for_executable_managed_observer(self):
        with mock.patch.object(observer.os, "access", return_value=True) as access:
            with mock.patch.object(observer, "classify", side_effect=AssertionError("suppressed")):
                self.assertEqual(self.observe("not JSON", delivery="codex-user"), "")
            access.assert_called_once_with("/etc/codex/hooks/agent-description-format-observe", os.X_OK)
            self.assertFalse(self.state.exists())
            for delivery in ("direct", "claude-user", "codex-managed"):
                self.observe(payload(), delivery=delivery)
        with mock.patch.object(observer.os, "access", return_value=False):
            self.observe(payload(), delivery="codex-user")
        self.assertEqual(len(self.events()), 4)
        self.assertEqual({e["delivery"] for e in self.events()}, set(observer.DELIVERIES))
        self.assertEqual(observer.report(str(self.state))["attempts"], 4)

    def test_large_pipe_input_is_consumed_before_quiet_returns(self):
        large = json.dumps({"padding": "x" * (128 * 1024)})
        for mode, end in (("off", self.config["end_at"]), ("observe", "2000-01-01T00:00:00Z")):
            with self.subTest(mode=mode):
                self.config.update(mode=mode, end_at=end)
                self.save_config()
                with subprocess.Popen([sys.executable, str(SCRIPT), "hook", "--config", str(self.config_path)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                    # Unlike communicate(), these writes expose an early closed
                    # pipe as BrokenPipeError instead of silently swallowing it.
                    try:
                        self.assertEqual(process.stdin.write(large.encode()), len(large))
                        process.stdin.close()
                        process.wait(timeout=5)
                        self.assertEqual((process.returncode, process.stdout.read(), process.stderr.read()), (0, b"", b""))
                    finally:
                        if process.poll() is None:
                            process.kill()
        self.assertFalse(self.state.exists())

    def test_stdin_read_is_bounded_even_when_observation_is_off(self):
        self.config["mode"] = "off"
        self.save_config()
        stream = io.BytesIO(b"x" * (observer.MAX_INPUT + 100))
        self.assertEqual(observer.hook(str(self.config_path), stream), 0)
        self.assertEqual(stream.tell(), observer.MAX_INPUT + 1)
        self.assertFalse(self.state.exists())

    def test_off_missing_and_expired_configs_are_quiet_and_collect_nothing(self):
        for path in (None, str(self.root / "missing.json")):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(observer.hook(path, io.StringIO("not JSON")), 0)
            self.assertEqual(out.getvalue() + err.getvalue(), "")
        self.config["mode"] = "off"
        self.save_config()
        self.assertEqual(self.observe("not JSON"), "")
        self.config["mode"] = "observe"
        self.config["end_at"] = "2000-01-01T00:00:00Z"
        self.save_config()
        self.assertEqual(self.observe(payload(body=MARKER)), "")
        self.assertFalse(self.state.exists())

    def test_end_is_rechecked_under_lock(self):
        config = observer.load_config(str(self.config_path))
        with mock.patch.object(observer, "utc_now", return_value=config["end"]):
            observer.append_event(config, {"ignored": True})
        self.assertEqual(self.events(), [])

    def test_malformed_payload_and_config_errors_always_allow(self):
        for data in ("{", "null", "[]", {"tool_name": "Bash", "tool_input": None},
                     {"tool_name": "mcp__forgejo__create_issue", "tool_input": "bad"}):
            self.observe(data)
        self.assertEqual([e["outcome"] for e in self.events()], ["error"] * 5)
        for invalid in ("{", "[]", json.dumps({**self.config, "mode": "enforce"}),
                        json.dumps({**self.config, "end_at": "not a date"}),
                        json.dumps({k: v for k, v in self.config.items() if k != "forgejo_host"})):
            self.config_path.write_text(invalid)
            self.observe(payload(body=MARKER))
        self.assertEqual(len(self.events()), 5)

    def test_observer_never_alters_or_prevents_mock_outgoing_write(self):
        for data in (payload(body=MARKER), payload("update_issue", None),
                     bash("gh pr create -R github.com/example/project --body '$BODY'"),
                     {"tool_name": "other", "tool_input": {"body": MARKER}}):
            original = copy.deepcopy(data)
            outgoing = mock.Mock()
            self.observe(data)
            outgoing(data)
            outgoing.assert_called_once_with(original)
            self.assertEqual(data, original)
        with mock.patch.object(observer, "validate", side_effect=RuntimeError(MARKER)):
            original = payload()
            self.observe(original)
            self.assertEqual(original, payload())

    def test_logging_failure_and_lock_timeout_allow(self):
        with mock.patch.object(observer, "append_event", side_effect=OSError(MARKER)):
            self.observe(payload())
        with observer.locked_state(str(self.state), create=True):
            self.observe(payload())
        self.assertEqual(self.events(), [])

    def test_telemetry_is_allowlisted_with_no_body_command_hash_or_session(self):
        data = payload(body=MARKER)
        data.update(session_id=MARKER, cwd=MARKER)
        self.observe(data)
        self.observe(bash("gh pr create -R github.com/example/project -b " + single_quote(MARKER)))
        self.observe({"tool_name": MARKER, "tool_input": {"body": MARKER}})
        allowed = {"schema", "version", "timestamp", "route", "target", "kind", "outcome", "rules", "elapsed_ms", "delivery"}
        for event in self.events():
            self.assertLessEqual(set(event), allowed)
            self.assertNotIn(MARKER, json.dumps(event))
            for diagnostic in event.get("rules", []):
                self.assertEqual(set(diagnostic), {"rule", "line"})
        summary = observer.report(str(self.state))
        self.assertNotIn(MARKER, json.dumps(summary))
        self.assertEqual(summary["attempts"], 3)
        self.assertEqual(summary["outcomes"], {"invalid": 2, "skip": 1})
        self.assertEqual(summary["routes"], {"forgejo": 1, "gh": 1, "unmatched": 1})
        self.assertEqual(summary["candidates"], 2)
        self.assertTrue(summary["counts_attempts_not_api_success"])

    def test_permissions_retention_and_report_window(self):
        with mock.patch.object(observer, "LOG_BYTES", 600):
            for _ in range(30):
                self.observe(payload())
            files = list(self.state.glob("events.jsonl*"))
            self.assertEqual(len(files), 4)
            self.assertLessEqual(sum(f.stat().st_size for f in files), 4 * 600)
            for file in files + [self.state / "events.lock"]:
                self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
            summary = observer.report(str(self.state))
            self.assertEqual(summary["attempts"], len(self.events()))
            self.assertLess(summary["attempts"], 30)
            self.assertEqual(summary["retention"]["bytes_per_file"], 600)
            self.assertIsNotNone(summary["retention"]["oldest"])
            self.assertIsNotNone(summary["retention"]["newest"])

    def test_concurrent_process_append_and_report_are_coherent(self):
        command = [sys.executable, str(SCRIPT), "hook", "--config", str(self.config_path)]

        def invoke(_):
            result = subprocess.run(command, input=json.dumps(payload()), text=True, capture_output=True, check=False)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
            return observer.report(str(self.state))["attempts"]

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            counts = list(pool.map(invoke, range(24)))
        self.assertTrue(all(1 <= count <= 24 for count in counts))
        self.assertEqual(observer.report(str(self.state))["attempts"], 24)
        self.assertEqual(len(self.events()), 24)

    def test_report_empty_and_corrupt_records_never_echoes_input(self):
        self.assertEqual(observer.report(str(self.state))["attempts"], 0)
        self.observe(payload())
        with (self.state / "events.jsonl").open("a") as stream:
            stream.write(MARKER + "\n")
            stream.write(json.dumps({"route": MARKER, "outcome": "skip"}) + "\n")
        summary = observer.report(str(self.state))
        self.assertEqual(summary["attempts"], 1)
        self.assertEqual(summary["malformed_records"], 2)
        self.assertNotIn(MARKER, json.dumps(summary))

    def test_report_preserves_untagged_direct_events_and_rejects_unknown_delivery(self):
        self.observe(payload())
        event = self.events()[0]
        del event["delivery"]
        with (self.state / "events.jsonl").open("w") as stream:
            stream.write(json.dumps(event) + "\n")
            stream.write(json.dumps({**event, "delivery": MARKER}) + "\n")
        summary = observer.report(str(self.state))
        self.assertEqual(summary["attempts"], 1)
        self.assertEqual(summary["malformed_records"], 1)
        self.assertEqual(summary["deliveries"], {"direct": 1})
        self.assertEqual(summary["delivery_outcomes"], {"direct": {"valid": 1}})
        self.assertNotIn(MARKER, json.dumps(summary))


class CLITests(unittest.TestCase):
    def run_cli(self, *args, body=""):
        return subprocess.run([sys.executable, str(SCRIPT), *args], input=body, text=True,
                              capture_output=True, check=False)

    def test_validate_exit_status_and_capped_json(self):
        for kind, body in (("issue", ISSUE), ("pr", PR)):
            result = self.run_cli("validate", "--kind", kind, body=body)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {"valid": True, "diagnostics": []})
        result = self.run_cli("validate", "--kind", "issue", body=MARKER)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["valid"])
        self.assertNotIn(MARKER, result.stdout + result.stderr)

    def test_hook_without_config_is_quiet_even_for_bad_input(self):
        result = self.run_cli("hook", body="not JSON")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_hook_argument_errors_also_allow_without_echoing_arguments(self):
        for args in (("--config",), ("--unknown", MARKER), ("--config", MARKER, "extra"),
                     ("--delivery", MARKER), ("--delivery", "direct", "--delivery", MARKER)):
            with self.subTest(args=args):
                result = self.run_cli("hook", *args, body="not JSON")
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn(MARKER, result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
