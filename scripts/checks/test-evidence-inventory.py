#!/usr/bin/env python3
"""Offline parser and HTTP contract tests for evidence-inventory."""

import datetime
import http.server
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.parse

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "modules/home-manager/programs/ai/evidence-inventory.py"
FIXTURE = json.loads((ROOT / "scripts/checks/fixtures/evidence-inventory.json").read_text())
spec = importlib.util.spec_from_file_location("evidence_inventory", SCRIPT)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)
NOW = inventory.parse_time(FIXTURE["now"])
TOKEN = "synthetic-credential-must-not-appear"


class Parsing(unittest.TestCase):
    def test_status_and_end_date(self):
        for body, status, end_date in FIXTURE["statusCases"]:
            with self.subTest(body=body):
                self.assertEqual(inventory.status_fields(body), (status, end_date))
        self.assertEqual(inventory.status_fields('**Status:** Blocked on \\_private and `foo_bar` (~2 days).'),
                         ('Blocked on _private and foo_bar (~2 days).', None))
        self.assertEqual(inventory.status_fields('<!--\n**Status:** Ended 2026-10-01.\n-->\n**Status:** Active until 2026-11-01.'),
                         ('Active until 2026-11-01.', '2026-11-01'))
        self.assertEqual(inventory.status_fields('**Status:** Waiting for `<!--` marker until 2026-11-01.'),
                         ('Waiting for <!-- marker until 2026-11-01.', '2026-11-01'))
        self.assertEqual(inventory.status_fields('**Status:** Use \\``<!--` then wait until 2026-11-01.'),
                         ('Use `<!-- then wait until 2026-11-01.', '2026-11-01'))
        self.assertEqual(inventory.status_fields('**Status:** Waiting for \\```<!--`` marker until 2026-11-01.'),
                         ('Waiting for `<!-- marker until 2026-11-01.', '2026-11-01'))
        for prefix, suffix in (("Don`t forget.", "**Status:** Active until `2026-11-01`."),
                               ('A literal \\` marker.', '**Status:** Active until 2026-11-01.\nAnother literal \\` marker.')):
            self.assertEqual(inventory.status_fields(prefix + '\n<!--\n**Status:** Ended 2026-10-01.\n-->\n' + suffix),
                             ('Active until 2026-11-01.', '2026-11-01'))

    def test_closed_days(self):
        issue = {"state": "closed", "closed_at": "2026-09-24T12:00:00Z"}
        self.assertTrue(inventory.include_issue(issue, NOW, 30))
        self.assertFalse(inventory.include_issue(issue, NOW, 29))
        issue["closed_at"] = "2026-09-24T11:59:59Z"
        self.assertFalse(inventory.include_issue(issue, NOW, 30))
        for value in (None, "invalid"):
            issue["closed_at"] = value
            self.assertFalse(inventory.include_issue(issue, NOW, 30))
        issue.update(state="open", closed_at=None)
        self.assertTrue(inventory.include_issue(issue, NOW, 0))
        issue["pull_request"] = {"merged": False}
        self.assertFalse(inventory.include_issue(issue, NOW, 30))

    def test_last_comment_page(self):
        client = inventory.Forgejo("https://forge.example", TOKEN)
        client.server_time = int(NOW.timestamp())
        rows = [dict(FIXTURE['lastComment'], id=i, updated_at=FIXTURE['lastComment']['created_at'],
                     issue_url='https://forge.example/api/v1/repos/example/alpha/issues/1') for i in range(1, 89)]
        other = dict(rows[-1], id=89, issue_url='', pr_url='https://forge.example/api/v1/repos/example/alpha/pulls/2')

        def get(path, params, count_only=False):
            selected = [r for r in rows if inventory.parse_time(params['since']) <= inventory.parse_time(r['updated_at']) <= inventory.parse_time(params['before'])]
            if path == '/repos/example/alpha/issues/comments' and selected:
                selected.append(other)
            if count_only:
                return len(selected)
            if 'page' in params:
                return selected[params['page'] - 1:params['page']]
            self.assertEqual(len(selected), 1, 'read many issue comment bodies')
            return selected

        client.get = unittest.mock.Mock(side_effect=get)
        with unittest.mock.patch.object(inventory.time, 'time', return_value=NOW.timestamp()):
            self.assertEqual(client.last_comment('example/alpha', 1, 88)['id'], 88)
        self.assertEqual([call.args[1]['page'] for call in client.get.call_args_list
                          if 'page' in call.args[1] and not call.kwargs.get('count_only')], [89, 88])
        client.get.reset_mock()
        self.assertIsNone(client.last_comment("example/alpha", 1, 0))
        client.get.assert_not_called()
        client.get.side_effect = lambda *args, **kwargs: 0
        with self.assertRaisesRegex(inventory.Fail, "last comment unavailable"):
            client.last_comment("example/alpha", 1, 88)

    def test_edited_old_comment(self):
        client = inventory.Forgejo('https://forge.example', TOKEN)
        client.server_time = int(NOW.timestamp())
        comments = [dict(FIXTURE['lastComment'], id=1, created_at='2026-10-20T00:00:00Z', updated_at='2026-10-24T00:00:00Z'),
                    dict(FIXTURE['lastComment'], id=2, created_at='2026-10-23T00:00:00Z', updated_at='2026-10-23T00:00:00Z')]

        def get(path, params, count_only=False):
            rows = [c for c in comments if inventory.parse_time(params['since']) <= inventory.parse_time(c['updated_at']) <= inventory.parse_time(params['before'])]
            return len(rows) if count_only else rows

        client.get = get
        with unittest.mock.patch.object(inventory.time, 'time', return_value=NOW.timestamp()):
            self.assertEqual(client.last_comment('example/alpha', 1, 2)['id'], 2)
        comments[:] = [dict(comments[1], created_at='2026-10-24T11:59:50Z', updated_at='2026-10-24T11:59:50Z')]
        with unittest.mock.patch.object(inventory.time, 'time', return_value=NOW.timestamp() - 30):
            self.assertEqual(client.last_comment('example/alpha', 1, 1)['id'], 2)

    def test_malformed_comment(self):
        for field in ('issue_url', 'created_at', 'id'):
            with self.subTest(field=field):
                with self.assertRaisesRegex(inventory.Fail, 'invalid comment response'):
                    inventory.checked_comment(dict(FIXTURE['lastComment'], **{field: None}))

    def test_request_budget(self):
        client = inventory.Forgejo("https://forge.example", TOKEN)
        client.deadline = 0
        with self.assertRaisesRegex(inventory.Fail, "runtime budget exhausted"):
            client.search("evidence-log")
        client.deadline = time.monotonic() + 1
        response = unittest.mock.MagicMock()
        response.__enter__.return_value = response
        response.read1.side_effect = lambda size: (time.sleep(0.02), b' ')[1]
        client.opener.open = unittest.mock.Mock(return_value=response)
        with unittest.mock.patch.object(inventory, 'REQUEST_TIMEOUT', 0.05):
            started = time.monotonic()
            with self.assertRaisesRegex(inventory.Fail, 'request time budget exhausted'):
                client.get('/repos/issues/search', {})
            self.assertLess(time.monotonic() - started, 0.3)
        response.read1.reset_mock()
        response.headers = {'X-Total-Count': '88'}
        self.assertEqual(client.get('/repos/example/alpha/issues/1/comments', {}, count_only=True), 88)
        response.read1.assert_not_called()

    def test_sorting_and_comment_failure(self):
        client = unittest.mock.Mock()
        client.search.return_value = FIXTURE["issues"]

        def comment(repo, number, count):
            if number == 2:
                raise inventory.Fail("HTTP 503")
            return FIXTURE["lastComment"] if count else None

        client.last_comment.side_effect = comment
        result = inventory.inventory(client, "evidence-log", 30, NOW)
        self.assertEqual([r["number"] for r in result["issues"]], [5, 1, 2, 7, 3])
        self.assertEqual(result["errors"], [{"repo": "example/alpha", "number": 2, "message": "HTTP 503"}])
        failed = result["issues"][2]
        self.assertIsNone(failed["lastCommentAt"])
        self.assertIsNone(failed["lastCommentURL"])
        self.assertEqual(result["issues"][0]["repo"], "example/beta")
        self.assertEqual(result["generatedAt"], FIXTURE["now"])
        self.assertEqual(result["issues"][1]["lastCommentURL"], FIXTURE["lastComment"]["html_url"])
        # Compare instants, including timestamps using different UTC offsets.
        client.search.return_value = [dict(FIXTURE["issues"][4], number=n, updated_at=stamp) for n, stamp in (
            (8, "2026-10-24T12:00:00+02:00"), (9, "2026-10-24T11:00:00Z"))]
        self.assertEqual([r["number"] for r in inventory.inventory(client, "x", 0, NOW)["issues"]], [9, 8])


class HTTPContract(unittest.TestCase):
    def test_command(self):
        requests = []
        mode = ["ok"]

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                requests.append((parsed.path, query, self.headers.get("Authorization")))
                status = 200
                if parsed.path == "/api/v1/repos/issues/search":
                    page = int(query["page"][0])
                    body = FIXTURE["issues"][(page - 1) * 4:page * 4]
                    if mode[0] == "failure":
                        status, body = 500, {"message": TOKEN}
                    elif mode[0] == "redirect":
                        status, body = 302, []
                    elif mode[0] == "invalid":
                        body = {"message": TOKEN}
                    elif mode[0] == 'row':
                        body = [{"message": TOKEN}]
                elif parsed.path.endswith("/1/comments"):
                    body = [FIXTURE["lastComment"]] if inventory.parse_time(query['since'][0]) <= inventory.parse_time(FIXTURE['lastComment']['created_at']) <= inventory.parse_time(query['before'][0]) else []
                    if mode[0] == 'comment' and body:
                        body = [dict(body[0], issue_url=None)]
                else:
                    status, body = 503, {"message": TOKEN}
                self.send_response(status)
                self.send_header('X-Total-Count', str(len(body)))
                if status == 302:
                    self.send_header("Location", "/credential-must-not-follow")
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

        with tempfile.TemporaryDirectory() as temp:
            token_file = pathlib.Path(temp) / "token"
            token_file.write_text(TOKEN)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = {**os.environ, "FORGEJO_API_TOKEN_FILE": str(token_file),
                   "EVIDENCE_FORGEJO_URL": f"http://127.0.0.1:{server.server_port}"}

            def run(*args):
                return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], env=env,
                                      capture_output=True, text=True, timeout=10)

            try:
                result = run("--label", "custom-log", "--closed-days", "9999")
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                self.assertEqual((output["version"], output["label"]), (1, "custom-log"))
                self.assertEqual(output["errors"][0]["number"], 2)
                self.assertNotIn(TOKEN, result.stdout + result.stderr)
                self.assertNotIn(FIXTURE["lastComment"]["body"], result.stdout)
                self.assertEqual(inventory.parse_time(output["generatedAt"]).tzinfo, datetime.timezone.utc)
                searches = [q for path, q, auth in requests if path.endswith("/search")]
                self.assertEqual([q["page"] for q in searches], [["1"], ["2"], ["3"]])
                self.assertTrue(all(q["type"] == ["issues"] and q["state"] == ["all"]
                                    and q["labels"] == ["custom-log"] for q in searches))
                self.assertTrue(all(auth == "token " + TOKEN for path, q, auth in requests))
                self.assertTrue(any(path.endswith('/1/comments') for path, q, auth in requests))
                mode[0] = 'comment'
                result = run('--closed-days', '9999')
                self.assertEqual(result.returncode, 0, result.stderr)
                partial = json.loads(result.stdout)
                self.assertIn(1, [row['number'] for row in partial['issues']])
                self.assertIn({'repo': 'example/alpha', 'number': 1, 'message': 'invalid comment response'}, partial['errors'])
                for failure in ("failure", "redirect", "invalid", 'row'):
                    mode[0] = failure
                    result = run()
                    self.assertEqual(result.returncode, 3, failure)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("search failed", result.stderr)
                    self.assertNotIn(TOKEN, result.stderr)
                self.assertFalse(any(path == "/credential-must-not-follow" for path, _, _ in requests))
                self.assertEqual(run("--token", TOKEN).returncode, 2)
                self.assertEqual(run("--closed-days", "-1").returncode, 2)
                env["FORGEJO_API_TOKEN_FILE"] = str(pathlib.Path(temp) / "missing")
                result = run()
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
