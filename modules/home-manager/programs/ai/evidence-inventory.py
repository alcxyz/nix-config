"""Read labelled Forgejo evidence issues as versioned JSON, without writing.

FORGEJO_API_TOKEN_FILE supplies the credential; the package pins
EVIDENCE_FORGEJO_URL. Search failures exit 3, unreadable credentials exit 2.
Comment failures leave the issue listed with null last-comment fields and an
entry in errors. Four comment workers, eight-second request timeouts and a
40-second request budget keep ordinary inventories bounded.
"""

import argparse
import concurrent.futures
import datetime
import email.utils
import html
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UTC = datetime.timezone.utc
REQUEST_TIMEOUT = 8
RUNTIME_BUDGET = 40


class Fail(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


class Forgejo:
    def __init__(self, url, token):
        self.url = url.rstrip("/")
        self.token = token
        self.deadline = time.monotonic() + RUNTIME_BUDGET
        self.server_time = None
        self.opener = urllib.request.build_opener(NoRedirect)

    def get(self, path, params, count_only=False):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Fail("runtime budget exhausted")
        request = urllib.request.Request(
            f"{self.url}/api/v1{path}?{urllib.parse.urlencode(params)}",
            headers={"Authorization": "token " + self.token, "Accept": "application/json"},
        )
        try:
            with self.opener.open(request, timeout=min(REQUEST_TIMEOUT, remaining)) as response:
                try:
                    self.server_time = int(email.utils.parsedate_to_datetime(response.headers.get("Date")).timestamp())
                except (TypeError, ValueError, OverflowError):
                    pass
                if count_only:
                    count = int(response.headers["X-Total-Count"])
                    if count < 0:
                        raise ValueError
                    return count  # Close without reading comment bodies.
                chunks = []
                request_deadline = min(self.deadline, time.monotonic() + REQUEST_TIMEOUT)
                while True:
                    if time.monotonic() >= request_deadline:
                        raise Fail("request time budget exhausted")
                    chunk = response.read1(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                rows = json.loads(b"".join(chunks))
            if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
                raise Fail("invalid API response")
            if path.endswith("/comments"):
                for row in rows:
                    checked_comment(row)
            return rows
        except urllib.error.HTTPError as error:
            raise Fail(f"HTTP {error.code}") from None
        except (urllib.error.URLError, OSError, ValueError, TypeError, http.client.HTTPException):
            # Do not include response bodies, exception text or request headers.
            raise Fail("request failed or returned invalid JSON") from None

    def search(self, label):
        rows, page = [], 1
        while True:
            batch = self.get("/repos/issues/search", {
                "labels": label, "type": "issues", "state": "all", "limit": 50, "page": page,
            })
            if not batch:
                return rows
            for issue in batch:
                if (not all(isinstance(issue.get(key), kind) for key, kind in (
                    ("state", str), ("number", int), ("title", str), ("html_url", str),
                )) or not isinstance(issue.get("comments", 0), int)
                        or issue.get("comments", 0) < 0
                        or any(issue.get(key) is not None and not isinstance(issue[key], str)
                               for key in ("body", "created_at", "updated_at", "closed_at"))):
                    raise Fail("invalid search row")
                repository = issue.get("repository")
                if repository is not None and (not isinstance(repository, dict) or
                        not isinstance(repository.get("full_name"), str)):
                    raise Fail("invalid search repository")
            rows.extend(batch)
            # An empty page also works when the server caps the requested limit.
            page += 1

    def last_comment(self, repo, number, count):
        if count == 0:
            return None
        path = "/repos/" + "/".join(urllib.parse.quote(part, safe="") for part in repo.split("/"))
        issue_path = f"{path}/issues/{number}/comments"
        # Forgejo's issue-comments endpoint ignores pagination. Narrow its
        # updated-time window using count headers, without reading the bodies.
        # An edited old comment may be newest by update but not by creation, so
        # also search earlier windows until they precede the best creation time.
        if self.server_time is None:
            raise Fail("server time unavailable")
        lower, upper = 1, self.server_time + 1
        best, span = None, 86400
        while lower <= upper:
            start = max(lower, upper - span + 1)
            params = comment_window(start, upper)
            found = self.get(issue_path, params, count_only=True)
            if not found:
                upper, span = start - 1, span * 2
                continue
            while found > 1 and start < upper:
                middle = (start + upper + 1) // 2
                right = self.get(issue_path, comment_window(middle, upper), count_only=True)
                if right:
                    start, found = middle, right
                else:
                    upper = middle - 1
            params = comment_window(start, upper)
            if found == 1:
                rows = self.get(issue_path, params)
                candidate = rows[-1] if rows else None
            else:
                # Several comments updated in the same second: the repository
                # endpoint really is paginated. Read one-item pages from its
                # tail until the latest comment for this issue is found.
                repo_path = f"{path}/issues/comments"
                page = self.get(repo_path, {**params, "limit": 1, "page": 1}, count_only=True)
                candidate = None
                while page > 0:
                    rows = self.get(repo_path, {**params, "limit": 1, "page": page})
                    row = checked_comment(rows[0]) if rows else None
                    if row and row["issue_url"].rstrip("/").endswith(f"/{repo}/issues/{number}"):
                        candidate = row
                        break
                    page -= 1
            if not candidate:
                raise Fail("last comment unavailable")
            checked_comment(candidate)
            if best is None or (parse_time(candidate["created_at"]), candidate.get("id", 0)) > (parse_time(best["created_at"]), best.get("id", 0)):
                best = candidate
            lower, upper = int(parse_time(best["created_at"]).timestamp()), start - 1
            span = 86400
        if best is None:
            raise Fail("last comment unavailable")
        return best


def comment_window(start, end):
    def stamp(value):
        return datetime.datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")
    return {"since": stamp(start), "before": stamp(end)}


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return moment if moment.tzinfo else moment.replace(tzinfo=UTC)
    except ValueError:
        return None


def checked_comment(row):
    if (not all(isinstance(row.get(key), str) and row[key] for key in ("created_at", "html_url"))
            or not isinstance(row.get("issue_url"), str)
            or not parse_time(row["created_at"]) or type(row.get("id")) is not int):
        raise Fail("invalid comment response")
    return row


def plain_markdown(text):
    literals = {}

    def protect(match):
        key = f"\0{len(literals)}\0"
        literals[key] = match.group(2) if match.group(1) else match.group(3)
        return key

    text = re.sub(r"(`+)(.+?)\1|\\([\\`*_{}\[\]()#+.!>~<-])", protect, text.replace("\0", ""))
    text = re.sub(r"!?\[([^\]]*)\]\([^\n]*?\)", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"<(https?://[^>]+)>", r"\1", text)
    text = re.sub(r"<[^>]*>", "", text)
    text = re.sub(r"(\*\*|__|~~)(?=\S)(.+?)(?<=\S)\1", r"\2", text)
    text = re.sub(r"(?<!\w)([*_])(?=\S)(.+?)(?<=\S)\1(?!\w)", r"\2", text)
    for key, value in literals.items():
        text = text.replace(key, value)
    return " ".join(html.unescape(text).split())


def status_fields(body):
    body = re.sub(r"\\.|(`+)(?!`)[^\n]*?(?<!`)\1(?!`)|`+|<!--.*?(?:-->|\Z)",
                  lambda match: "" if match.group(0).startswith("<!--") else match.group(0),
                  body or "", flags=re.S)
    match = re.search(r"^\*\*Status:\*\*[^\S\n]*(.*)$", body, re.M)
    if not match:
        return None, None
    line = plain_markdown(match.group(1))
    sentence = re.search(r"^.*?[.!?](?:[\"')\]]*)(?=\s|$)", line)
    status = (sentence.group(0) if sentence else line) or None
    end_date = None
    for date in re.finditer(
        r"\b(?:ends?|ended|until|cutoff|deadline)\b[^.!?;\n]*?\b(\d{4}-\d{2}-\d{2})\b", line, re.I,
    ):
        try:
            end_date = datetime.date.fromisoformat(date.group(1)).isoformat()
            break
        except ValueError:
            continue
    return status, end_date


def include_issue(issue, now, closed_days):
    if issue.get("pull_request") is not None:
        return False
    if issue["state"] == "open":
        return True
    closed = parse_time(issue.get("closed_at"))
    return issue["state"] == "closed" and closed is not None and closed >= now - datetime.timedelta(days=closed_days)


def inventory(client, label, closed_days, now):
    issues = []
    for issue in client.search(label):
        if not include_issue(issue, now, closed_days):
            continue
        repo = (issue.get("repository") or {}).get("full_name")
        if not repo:
            repo = "/".join(urllib.parse.urlsplit(issue["html_url"]).path.strip("/").split("/")[:2])
        status, end_date = status_fields(issue.get("body"))
        issues.append({
            "repo": repo, "number": issue["number"], "title": issue["title"],
            "state": issue["state"], "url": issue["html_url"],
            "createdAt": issue.get("created_at"), "updatedAt": issue.get("updated_at"),
            "closedAt": issue.get("closed_at"), "comments": issue.get("comments", 0),
            "lastCommentAt": None, "lastCommentURL": None, "status": status, "endDate": end_date,
        })
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [(row, pool.submit(client.last_comment, row["repo"], row["number"], row["comments"])) for row in issues]
        for row, future in futures:
            try:
                comment = future.result()
                if comment:
                    row["lastCommentAt"] = comment.get("created_at")
                    row["lastCommentURL"] = comment.get("html_url")
            except Fail as error:
                errors.append({"repo": row["repo"], "number": row["number"], "message": str(error)})
    issues.sort(key=lambda row: (
        row["state"] != "open",
        -(parse_time(row["lastCommentAt"] or row["updatedAt"]) or datetime.datetime(1970, 1, 1, tzinfo=UTC)).timestamp(),
        row["repo"], row["number"],
    ))
    return {"version": 1, "generatedAt": now.isoformat().replace("+00:00", "Z"),
            "label": label, "issues": issues, "errors": errors}


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="evidence-log", help="issue label (default: evidence-log)")
    parser.add_argument("--closed-days", type=nonnegative, default=30, help="closed issue lookback in days (default: 30)")
    args = parser.parse_args()
    try:
        with open(os.environ["FORGEJO_API_TOKEN_FILE"], encoding="utf-8") as handle:
            token = handle.read().strip()
        if not token:
            raise ValueError
    except (KeyError, OSError, ValueError):
        print("evidence-inventory: FORGEJO_API_TOKEN_FILE must name a readable, nonempty file", file=sys.stderr)
        return 2
    client = Forgejo(os.environ.get("EVIDENCE_FORGEJO_URL", "https://git.alc.xyz"), token)
    try:
        result = inventory(client, args.label, args.closed_days, datetime.datetime.now(UTC))
    except Fail as error:
        print(f"evidence-inventory: search failed: {error}", file=sys.stderr)
        return 3
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
