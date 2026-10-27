"""Contract tests for pr-review and the agent PR review guard hook."""

import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "pr_review", ROOT / "modules/home-manager/programs/ai/pr-review.py"
)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
real_run = review.run
real_forgejo = review.forgejo_request
# The guard reads fast-forward repositories from here; tests set their own.
os.environ.pop("PR_REVIEW_CONFIG", None)

HEAD = "0123456789abcdef0123456789abcdef01234567"
PINNED = f"Automated read-only review ({HEAD[:12]} on dev): no blocking findings."
STALE = "Automated read-only review (fedcba987654 on dev): no blocking findings."
calls = []


def bodies_for(number):
    return {"7": ["LGTM", PINNED], "9": [STALE]}.get(number, ["LGTM"])


def fake_run(argv, cwd=None, stdin=None, timeout=None):
    calls.append((argv, cwd))
    joined = " ".join(argv)
    if argv[:3] == ["gh", "pr", "view"]:
        number = "7" if "reviewed" in joined or "7" in argv else "9" if "9" in argv else "5"
        host = "ghe.example" if "ghe" in joined else "github.com"
        return json.dumps({"bodies": bodies_for(number), "head": HEAD, "base": "dev",
                           "url": f"https://{host}/o/r/pull/{number}"})
    number = joined.split("/")[4].split()[0] if "/pulls/" in joined or "/issues/" in joined else "5"
    if "/comments" in joined:
        return "\n".join(json.dumps(body) for body in bodies_for(number))
    return json.dumps({"head": {"sha": HEAD}, "base": {"ref": "dev"}, "title": "t"})


def fake_forgejo(pr, path, data=None, accept="application/json"):
    calls.append((pr, path))
    if path.startswith("issues/"):
        return [{"body": body} for body in bodies_for(pr.number)]
    return {"head": {"sha": HEAD}, "base": {"ref": "dev"}, "title": "t"}


review.run = fake_run
review.forgejo_request = fake_forgejo


def hook(command, cwd="/work"):
    sys.stdin = io.StringIO(json.dumps({"tool_input": {"command": command}, "cwd": cwd}))
    sys.stderr = io.StringIO()
    try:
        return review.main(["guard"]), sys.stderr.getvalue()
    finally:
        sys.stdin, sys.stderr = sys.__stdin__, sys.__stderr__


def expect(command, status, cwd="/work"):
    calls.clear()
    code, message = hook(command, cwd)
    assert code == status, f"{command!r}: expected {status}, got {code}: {message}"
    if status == 2:
        assert "pr-review run <pr>" in message, message
    return list(calls), message


# Unrelated commands and non-merge calls pass without lookups.
assert not expect("git merge origin/main", 0)[0]
for command in ("git merge gh-pages", "git merge-base HEAD origin/gh-pages",
                "sed -n '/x/p' ~/.config/gh/merge.log", "python3 -m pytest tests/gh/"):
    assert not expect(command, 0)[0], command
assert not expect("gh pr view 5", 0)[0]
assert not expect("echo hello", 0)[0]
for command in ("for f in *; do case $f in *.md) echo instead;; esac; done",
                "printf $'it\\'s a team'", "echo teardown >| result"):
    assert not expect(command, 0)[0], command

# Quoted arguments of unrelated commands and heredoc bodies are data. Text
# containing quotes, separators, merge URLs and << must not steer lookups.
for command in (
    "git commit -m 'gh pr merge 9'",
    "git -C child commit -m 'gh pr merge 9'",
    "git commit -m '-c gh pr merge 9'",
    "MSG='gh pr merge 9' git commit -m prose",
    "GIT_AUTHOR_NAME='gh pr merge 9' git log -1",
    '''MSG='docs: explain gh pr merge refusal'; git commit -m "$MSG" && git push''',
    '''MSG='docs: explain gh pr merge refusal'; git commit -m "$MSG" && python3 scripts/checks/test-pr-review.py''',
    '''MSG='docs: explain gh pr merge refusal'; git commit -m "$MSG" && nix flake check''',
    '''declare MSG='docs: explain gh pr merge refusal'; git commit -m "$MSG" && python3 build.py''',
    '''set -e; MSG='gh pr merge 9'; git commit -m "$MSG" && python3 build.py''',
    '''CMD='gh pr merge 9'; bash <<'EOF'\n$CMD\nEOF''',
    '''(cat) <<'EOF'\ngh pr merge 9\nEOF''',
    '''bash -s -- 'gh pr merge 9' <<'EOF'\nprintf '%s' "$1"\nEOF''',
    '''MSG='gh pr merge 9'; branch="$USER/fix"; git commit -m "$MSG" && python3 build.py "$branch"''',
    '''printf -v GIT_EXTERNAL_DIFF 'sh -c "gh pr merge 9"'; git diff --ext-diff''',
    '''BODY=$(cat <<'EOF'\nrefuse gh pr merge --auto\nEOF\n); git push -u origin fix && gh pr create --body "$BODY"''',
    "git grep -e '-Ogh pr merge 9' -- README.md",
    "git grep -O -e 'gh pr merge 9' -- README.md",
    "rg -e '--pre=gh pr merge 9' .",
    "rg -- '--pre' 'gh pr merge 9'",
    "sort -- '--compress-program=gh pr merge 9'",
    "git push -o '--receive-pack=gh pr merge 9' origin HEAD",
    "git push -vo '--receive-pack=gh pr merge 9' origin HEAD",
    "git push --push-o '--receive-pack=gh pr merge 9' origin HEAD",
    '''MSG='gh pr merge 9'; git push --repo fallback origin "$branch"''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash -s script.sh <<< '' ''',
    '''bash -s 3<<< 'gh pr merge 9' <<< '' ''',
    '''bash -s 3<<< 'gh pr merge 9' <<< 'cat <&3' ''',
    "git commit -m 'gh pr merge 9' >| message.log",
    "tea pr create --title 'fix merge-guard follow-ups'",
    "tea pr create --title merge",
    "tea comment --message merge",
    "gh pr review 7 --body 'gh pr merge'",
    "gh release create v1 --notes 'gh pr merge'",
    "gh repo edit --enable-merge-commit",
    "gh run list --branch fix/merge-guard",
    'gh search prs "merge queue"',
    'pr-review run 670 --response "Kept tea merge refusal; gh pr merge --auto now refused"',
    "rg 'gh pr merge' .",
    "git commit -m gh 'pr' 'merge' '9'",
    "git commit -m 'https://git.example/api/v1/repos/o/r/pulls/9/merge'",
    "echo '<<EOF' 'gh pr merge 9'",
    "echo ';' gh pr merge 9",
    "cat <<'EOF'\ngh pr merge 9\nIt's prose: tea pulls merge 9\nEOF\n",
    "cat <<-\"END\"\n\tgh pr merge 9\n\tEND\n",
    "cat <<A <<'B'\ngh pr merge 9\nA\ntea pulls merge 9\nB\n",
    "bash -c cat <<'EOF'\ngh pr merge 9\nEOF\n",
    "cat <<< 'gh pr merge 9'",
    "cat <<'EOF'\n$(gh pr merge 9)\nEOF",
    "comm -13 <(git branch --merged main) <(git branch)",
    'grep -c merge <<< "$log"',
    "# gh pr merge 9\necho ok",
):
    assert not expect(command, 0)[0], command
expect("cat <<'EOF'\ngh pr merge 7\nEOF\ngh pr merge 9", 2)
expect("cat <<'EOF'\nIt's prose\nEOF\ngh pr merge 7", 0)
expect("cat <<''\n\ngh pr merge 9", 2)
expect("echo ok\ngh pr merge 9", 2)
expect("if true; then gh pr merge 9; fi", 2)
expect("gh pr merge 7 && gh pr merge 9", 2)
expect("'gh' 'pr' 'merge' 9", 2)
expect("gh pr merge 9 # It's a merge", 2)
expect("cat <<EOF\ngh pr merge 9", 2)
for command in ("gh pr merge 7 --auto", "gh pr merge 7 --auto=true",
                '''tea api -X POST /repos/o/r/pulls/7/merge -d '{"merge_when_checks_succeed": true}' ''',
                '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --data '{"merge_when_checks_succeed":true}' '''):
    seen, message = expect(command, 2)
    assert "delayed merges" in message and not seen, (command, message)
expect('''tea api -X POST /repos/o/r/pulls/7/merge -d '{"merge_when_checks_succeed": false}' ''', 0)
for command in (
    '''tea api -X POST /repos/o/r/pulls/7/merge --field merge_when_checks_succeed=true''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -d@body.json''',
    '''tea api -X POST /repos/o/r/pulls/7/merge -d @- <<'EOF'\n{"merge_when_checks_succeed":true}\nEOF''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --json '{"merge_when_checks_succeed":true}' ''',
):
    assert not expect(command, 2)[0], command
expect('''curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge -d '{"message":"--request GET"}' ''', 2)
expect("curl -XGET -XPOST https://git.example/api/v1/repos/o/r/pulls/9/merge", 2)
for command in (
    '''KEY=merge_when_checks_succeed; curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --json "{\\"Do\\":\\"squash\\",\\"$KEY\\":true}"''',
    '''curl -X GET https://git.example/api/v1/repos/o/r/pulls/7/merge --json '{"$KEY":true}' ''',
    '''tea api -X POST /repos/o/r/pulls/7/merge --field '$KEY=true' ''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --form-string '$KEY=true' ''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --data '`key`=true' ''',
):
    seen, message = expect(command, 2)
    assert "expanded merge payload" in message and not seen, (command, message)

# Only printf's options before the format select an assignment destination.
for command in (
    '''CMD='gh pr merge 9'; bash -c "$(printf '%s' "$CMD")"''',
    '''CMD='gh pr merge 9'; bash -c "`printf '%s' "$CMD"`"''',
    '''CMD='gh pr merge 9'; printf '%s\\n' "$CMD" > >(xargs -I{} bash -c '{}'); wait''',
    '''CMD='gh pr merge 9'; COPY="$CMD"; printf '%s' "$COPY" > >(xargs sh -c); wait''',
):
    assert not expect(command, 2)[0], command
for command in (
    '''gh repo clone git@github.com:o/r.git -- --config 'core.sshCommand=sh -c "gh pr merge 9 --repo o/r"' ''',
    '''gh repo fork o/r -- --config 'core.sshCommand=sh -c "gh pr merge 9 --repo o/r"' ''',
    '''export GH_REPO; printf -v GH_REPO other/repo; gh pr merge 7''',
    '''export GH_HOST; printf -v GH_HOST other.example; gh pr merge 7''',
    '''printf -v CDPATH other; cd repo; gh pr merge 7''',
    '''printf -v HOME other; cd; gh pr merge 7''',
    '''echo "$(case x in x) gh pr merge 9;; esac)"''',
    "git commit -m $'it\\'s done' && gh pr merge 9 # don't",
    '''printf "%'n" 'a[$(gh pr merge 9)]' ''',
    '''tea api -X POST /repos/o/r/pulls/7/merge -d '{"Do":"squash","MERGE_WHEN_CHECKS_SUCCEED":true}' ''',
    '''tea api -X POST /repos/o/r/pulls/7/merge --field MeRgE_WhEn_ChEcKs_SuCcEeD=true''',
):
    assert not expect(command, 2)[0], command
expect('''tea api -X POST /repos/o/r/pulls/7/merge -d '{"MERGE_WHEN_CHECKS_SUCCEED":false}' ''', 0)
for command in (
    '''GH_REPO+=other/repo; export GH_REPO; gh pr merge 7''',
    '''read -r GH_REPO <<< other/repo; export GH_REPO; gh pr merge 7''',
    '''mapfile -t GH_REPO <<< other/repo; gh pr merge 7''',
    '''readarray -t CDPATH <<< other; cd repo; gh pr merge 7''',
    '''export GH_REPO; gh pr merge 7''',
    '''unset GH_REPO; gh pr merge 7''',
    '''NAME=GH_REPO; unset "$NAME"; gh pr merge 7''',
    '''eval 'GH_REPO=other/repo'; gh pr merge 7''',
    '''let GH_REPO=123; gh pr merge 7''',
    '''getopts : GH_REPO a; gh pr merge 7''',
    '''git -c diff.external="$(printf '%s' 'sh -c "gh pr merge 9 --repo o/r"')" diff --ext-diff HEAD~1 HEAD''',
    '''curl -X POST 'https://git.example/{api/v1/repos/o/r/pulls/7/merge,api/v1/repos/o/r/pulls/9/merge}' --json '{"Do":"squash"}' ''',
    '''curl -X POST 'https://git.example/api/v1/repos/o/r/pulls/[7-9]/merge' --json '{"Do":"squash"}' ''',
):
    assert not expect(command, 2)[0], command
for shell in ("bash", "sh"):
    assert not expect(f'''git commit -m "fix(pr-review): quote gh output" && {shell} scripts/checks/test-agent-role.sh''', 0)[0]
# Opaque shell files stay conservative across one tool call, even after prose.
# Separate calls each receive their own context, without cross-call file tracking.
for separator in (" && ", "; ", "\n"):
    for shell in ("bash", "sh"):
        command = f'''git commit -m "explain gh pr merge"{separator}{shell} tests.sh'''
        seen, message = expect(command, 2)
        assert not seen and "shell script file" in message, (command, message)
assert not expect('git commit -m "explain gh pr merge"', 0)[0]
for shell in ("bash", "sh"):
    assert not expect(f"{shell} tests.sh", 0)[0]
seen, message = expect("git merge origin/dev && gh pr view 670 && bash tests.sh", 2)
assert not seen and "shell script file" in message, message
for command in (
    '''exec -c env HOME="$HOME" PATH="$PATH" bash -c 'gh pr merge 7' ''',
    '''exec -l bash -c 'gh pr merge 7' ''',
    '''exec -a login-shell bash -c 'gh pr merge 7' ''',
):
    seen, message = expect(command, 2)
    assert not seen and "wrapper option" in message, (command, message)
expect("exec gh pr merge 7", 0)
for variable, value in (("GH_REPO", "reviewed/repo"), ("GH_HOST", "github.com")):
    with patch.dict(os.environ, {variable: value}):
        for prefix in ("sudo", "sudo -E", 'sudo -u "$USER"', "sudo --preserve-env"):
            for command in (f"{prefix} gh pr merge 7", f"{prefix} bash -c 'gh pr merge 7'"):
                seen, message = expect(command, 2)
                assert not seen and "sudo's handling" in message, (command, message)
for command in (
    '''GIT_PAGER=bash git --paginate log -1 --format='format:gh pr merge 9 --repo o/r' ''',
    '''export GIT_PAGER=bash; git log -1 --format='format:gh pr merge 9 --repo o/r' ''',
    '''env -u GH_REPO gh pr merge 7''',
    '''env --unset=GH_HOST gh pr merge 7''',
    '''env -uGH_REPO gh pr merge 7''',
    '''env -i gh pr merge 7''',
    '''zsh -f -c 'local GH_REPO=other/repo; gh pr merge 7' ''',
    '''unset -m 'GH_*'; gh pr merge 7''',
    ''': ${CDPATH:=/other}; cd repo && gh pr merge 7''',
    ''': ${GH_REPO=other/repo}; gh pr merge 7''',
    '''((CDPATH=1)); cd repo && gh pr merge 7''',
    '''echo "$((CDPATH=1))"; cd repo && gh pr merge 7''',
):
    assert not expect(command, 2)[0], command
assert not expect('''export MSG='gh pr merge 9'; bash -c 'git commit -m "$MSG"' ''', 0)[0]
expect('''git commit -m '${CDPATH:=/other} gh pr merge 9'; cd repo && gh pr merge 7''', 0)
for command in (
    '''git -c core.pager=bash log -1 --format='format:gh pr merge 9 --repo o/r' ''',
    '''URL='https://git.example/api/v1/repos/o/r/pulls/9/merge'; curl -X POST "$URL" --json '{}' ''',
    '''HEADER='x: y --next'; curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -H $HEADER --json '{}' ''',
    '''OPTS='--json {"Do":"squash","merge_when_checks_succeed":true}'; curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge $OPTS''',
    '''noglob cd child && gh pr merge 7''',
    '''nocorrect cd child && gh pr merge 7''',
    '''tea api -X POST /repos/o/r/pulls/7/merge -d '{"merge_when_checkſ_succeed":true}' ''',
    '''git -c pager.log=bash log -1 --format='format:gh pr merge 9 --repo o/r' ''',
    '''MERGE_OPTION=--auto; gh pr merge 7 "$MERGE_OPTION"''',
    '''MSG='text --auto'; gh pr merge 7 --body $MSG''',
    '''MSG='text --auto'; gh pr merge 7 --body=$MSG''',
    '''gh pr merge 7 --body=$(printf 'text --auto')''',
    '''gh api -X PUT repos/o/r/pulls/7/merge --paginate''',
    '''gh api -X PUT repos/o/r/pulls/7/merge --template 'gh pr merge 9' | bash''',
):
    assert not expect(command, 2)[0], command
for command in (
    '''MSG='text --auto'; gh pr merge 7 --body "$MSG"''',
    '''MSG='text --auto'; gh pr merge 7 "--body=$MSG"''',
    '''gh pr merge 7 --body="$(printf 'text --auto')"''',
    '''gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash --jq .merged''',
    '''gh api -X PUT repos/o/r/pulls/7/merge -q .merged --cache 60s''',
    '''gh api -X PUT repos/o/r/pulls/7/merge --template '{{.merged}}' ''',
    '''HEADER='x: y --next'; curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -H "$HEADER" --json '{}' ''',
):
    expect(command, 0)

for command in (
    '''printf -v unused -v 'a[$(gh pr merge 9)]' '%s' text''',
    '''printf -vunused -vother '%s' 'gh pr merge 9' ''',
    '''printf '%n' 'a[$(gh pr merge 9)]' ''',
    '''FORMAT='%n'; printf "$FORMAT" 'a[$(gh pr merge 9)]' ''',
):
    assert not expect(command, 2)[0], command
for command in (
    '''printf '%s' -v 'gh pr merge 9' ''',
    '''printf -- '%s' -v 'gh pr merge 9' ''',
    '''printf -v MSG -- '%s' 'gh pr merge 9'; git commit -m "$MSG"''',
    '''printf '%%n %s' 'gh pr merge 9' ''',
):
    assert not expect(command, 0)[0], command

# Execution wrappers and leading redirections do not turn executable merges
# into data. Their options are interpreted before locating the real client.
for prefix in ("timeout 120", "timeout -k 5 120", "time", "sudo -E", "sudo -u root",
               "env --", "env -u TERM", "env -uTERM", "</dev/null", "2>/dev/null",
               "nice -n 10", "stdbuf -oL"):
    expect(f"{prefix} gh pr merge 9", 2)
    expect(f"{prefix} gh pr merge 7", 0)
    expect(f"{prefix} tea pulls merge 9", 2)
    expect(f"{prefix} curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge -d '{{}}'", 2)
expect("env --chdir other gh pr merge 7", 2)
for command in (
    "nix shell nixpkgs#gh -c gh pr merge 9 --squash",
    "nix develop -c gh pr merge 9",
    "setsid gh pr merge 9",
    "echo 9 | xargs gh pr merge",
    "flock /tmp/l gh pr merge 9",
    '''python3 -c "urlopen(Request('https://git.example/api/v1/repos/o/r/pulls/9/merge', method='POST'))"''',
    "http POST https://git.example/api/v1/repos/o/r/pulls/9/merge",
    "python3 <<'EOF'\nurl = 'https://git.example/api/v1/repos/o/r/pulls/9/merge'\nEOF",
    "gh pr --repo o/r merge 9",
):
    seen, message = expect(command, 2)
    assert "unsupported executable context" in message and not seen, (command, message)
expect("export GH_REPO=other/repo && gh pr merge 7", 2)
expect("export GH_HOST=ghe.example ; gh api -X PUT repos/o/r/pulls/7/merge", 2)
expect("bash <<'EOF'\ngh pr merge 9\nEOF", 2)
expect("bash -c 'gh pr merge 9'", 2)
for command in (
    '''bash -c 'exec "$@"' _ gh pr merge 9 --repo o/r''',
    '''bash -c '$1 $2 $3 $4' _ gh pr merge 9''',
    '''bash -c 'git push "$@"' _ --receive-pack='sh -c "gh pr merge 9"' /tmp/repo''',
    '''bash -c 'sort "$@"' _ --compress-program='sh -c "gh pr merge 9"' input''',
    '''bash -c 'printf "$@"' _ -v 'a[$(gh pr merge 9)]' text''',
    '''git grep --open-files-in-pager='sh -c "gh pr merge 9"' -e fix -- README.md''',
    '''git grep -O'sh -c "gh pr merge 9"' -e fix -- README.md''',
    '''git grep -nO'sh -c "gh pr merge 9"' -e fix -- README.md''',
    '''git grep --open-files-in='sh -c "gh pr merge 9"' -e fix -- README.md''',
    '''git push --receive-pack='sh -c "gh pr merge 9"' /tmp/repo HEAD''',
    '''git push --receive-p='sh -c "gh pr merge 9"' /tmp/repo HEAD''',
    '''export GIT_EXTERNAL_DIFF; printf -v GIT_EXTERNAL_DIFF 'sh -c "gh pr merge 9"'; git diff --ext-diff''',
    '''export GIT_EXTERNAL_DIFF; CMD='sh -c "gh pr merge 9"'; printf -v GIT_EXTERNAL_DIFF '%s' "$CMD"; git diff --ext-diff''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash script.sh''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash script.sh <<< '' ''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash -- script.sh <<'DATA'\nprose\nDATA''',
    '''export GIT_EXTERNAL_DIFF; dest=GIT_EXTERNAL_DIFF; printf -v "$dest" 'sh -c "gh pr merge 9"'; git diff --ext-diff''',
    '''git -c protocol.ext.allow=always push 'ext::gh pr merge 9 --repo o/r' HEAD''',
    '''git push -- 'ext::gh pr merge 9 --repo o/r' HEAD''',
    '''REMOTE='ext::gh pr merge 9 --repo o/r'; git push "$REMOTE" HEAD''',
    '''git push --repo='ext::gh pr merge 9 --repo o/r' HEAD''',
    '''git push --rep='ext::gh pr merge 9 --repo o/r' ''',
    '''REMOTE='ext::gh pr merge 9'; git push --repo origin "$REMOTE" HEAD''',
    '''git push --repo origin 'ext::gh pr merge 9 --repo o/r' HEAD''',
    '''git push -vo note 'ext::gh pr merge 9 --repo o/r' HEAD''',
    '''git push --push-o note 'ext::gh pr merge 9 --repo o/r' HEAD''',
    '''git push --unknown-option note 'ext::gh pr merge 9 --repo o/r' HEAD''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash -s <script.sh 3<<< '' ''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash -s <<< '' <script.sh''',
    '''printf '%s\\n' 'gh pr merge 9' > script.sh; bash <<< '' <script.sh''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash <<< '' 0<&3''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash <<< '' 0<>script.sh''',
    '''bash -s 3<<< 'gh pr merge 9' <<< '' 0>&3''',
    '''bash -s 3<<< 'gh pr merge 9' <<< "$(cat /dev/fd/3)"''',
    '''bash -s 3<<< 'gh pr merge 9' <<< '. /dev/fd/3' ''',
    '''bash -s 3<<< 'gh pr merge 9' <<< 'source /dev/fd/3' ''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash --rcfile script.sh -ic true''',
    '''sort --compress-program='sh -c "gh pr merge 9"' -S1b input''',
    '''rg --pre='sh -c "gh pr merge 9"' pattern input''',
):
    assert not expect(command, 2)[0], command
assert not expect('''bash -c 'printf "%s" "$1"' _ 'gh pr merge 9' ''', 0)[0]
for option in ("--", "-e", "-ex", "-o errexit"):
    expect(f"bash -c {option} 'gh pr merge 9'", 2)
    seen, _ = expect(f"bash -c {option} 'gh pr merge 7'", 0)
    assert seen, option
for option in ("-cO extglob", "-Oc extglob", "-c -O extglob"):
    expect(f"bash {option} 'gh pr merge 9'", 2)
for option in ("+e", "+x", "+O extglob", "+o errexit", "-"):
    expect(f"bash -c {option} 'gh pr merge 9'", 2)
    if option == "-":
        assert expect(f"bash -c {option} 'gh pr merge 7'", 0)[0]
for command in ("echo 'gh pr merge 9' > >(bash)",
                "cat <<'EOF' > >(bash)\ngh pr merge 9\nEOF",
                "echo 'gh pr merge 9' > >(python3)",
                "echo 'gh pr merge 9' > >(tee >(bash))"):
    assert not expect(command, 2)[0], command
assert not expect("echo 'gh pr merge 9' > >(cat)", 0)[0]
for command in (
    '''git -c 'diff.external=sh -c "gh pr merge 9 --squash"' diff --ext-diff HEAD~1 HEAD''',
    '''git -ccore.pager='gh pr merge 9' log''',
    '''exec 3> >(bash); printf '%s\\n' 'gh pr merge 9' >&3; exec 3>&-; wait''',
    '''exec > >(bash); echo 'gh pr merge 9' ''',
    '''exec 3< <(echo 'gh pr merge 9'); bash <&3''',
    '''exec 3<<< 'gh pr merge 9'; bash <&3''',
    '''PAGER_CMD='sh -c "gh pr merge 9"' git --config-env=core.pager=PAGER_CMD --paginate log -1''',
    '''export PAGER_CMD='sh -c "gh pr merge 9"'; git --config-env core.pager=PAGER_CMD --paginate log -1''',
    '''PAGER_CMD='gh pr merge 9' bash -c 'git --config-env=core.pager=PAGER_CMD --paginate log -1' ''',
    '''export PAGER_CMD='gh pr merge 9'; bash -c 'git --config-env=core.pager=PAGER_CMD --paginate log -1' ''',
    '''PAGER_CMD='gh pr merge 9' git -c core.pager="$PAGER_CMD" --paginate log -1''',
    '''CMD='gh pr merge 9' python3 -c 'import os; os.system(os.environ["CMD"])' ''',
    '''exec {merge_fd}> >(bash); printf '%s\\n' 'gh pr merge 9' > /dev/fd/$merge_fd; wait''',
    '''{merge_fd}> >(bash); printf '%s\\n' 'gh pr merge 9' > /dev/fd/$merge_fd; wait''',
    '''curl -X GET https://api.github.com/repos/o/r/pulls/7/merge -o /dev/null --write-out 'gh pr merge 9\\n' | bash''',
):
    assert not expect(command, 2)[0], command
for variable in ("GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EDITOR", "GIT_SSH_COMMAND", "GIT_CONFIG_PARAMETERS"):
    assert not expect(f"{variable}='sh -c \"gh pr merge 9\"' git diff --ext-diff HEAD~1 HEAD", 2)[0]
for command in (
    '''CMD='sh -c "gh pr merge 9"' GIT_EXTERNAL_DIFF="$CMD" git diff --ext-diff HEAD~1 HEAD''',
    '''X='sh -c "gh pr merge 9"'; Y=$X; GIT_EXTERNAL_DIFF=$Y git diff --ext-diff HEAD~1 HEAD''',
    '''GIT_EXTERNAL_DIFF=$(echo 'sh -c "gh pr merge 9"') git diff --ext-diff HEAD~1 HEAD''',
    '''GH_BROWSER='sh -c "gh pr merge 9"' gh search prs x --web''',
    '''CMD='gh pr merge 9' GH_BROWSER=$CMD gh pr view 7 --web''',
    '''GH_PAGER='gh pr merge 9' gh pr view 7''',
    '''LESSOPEN='|gh pr merge 9' git log -1''',
):
    assert not expect(command, 2)[0], command
for options in ("+e -c", "-c +e", "-cO extglob", "--unsupported -c", "-z -c"):
    assert not expect(f"CMD='gh pr merge 9' bash {options} '$CMD'", 2)[0], options
for variable, value in (("SHELLOPTS", "allexport"), ("BASHOPTS", "extdebug"), ("BASH_ENV", "./startup.sh"), ("ENV", "./startup.sh")):
    previous = os.environ.get(variable)
    try:
        os.environ[variable] = value
        assert not expect('''bash -c 'GIT_EXTERNAL_DIFF="gh pr merge 9"; git diff --ext-diff' ''', 2)[0]
    finally:
        if previous is None:
            os.environ.pop(variable, None)
        else:
            os.environ[variable] = previous
for command in (
    '''tea api -X POST /repos/o/r/pulls/7/merge -d '{"Do":"squash"}' | jq .''',
    '''gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash | jq .merged''',
    "gh pr merge 7 | sed -n '1p'",
    "bash -c 'gh pr merge 7 --repo o/r' </dev/null 2>&1",
    "zsh -f -c 'gh pr merge 7 --repo o/r'",
    "zsh -fc 'gh pr merge 7 --repo o/r'",
    "bash -c 'gh pr merge 7 --repo o/r' <&-",
    "exec 3</dev/null; gh pr merge 7 --repo o/r",
    "curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -w '%{http_code}' | jq .",
):
    assert expect(command, 0)[0], command
for command in ("bash < <(echo 'gh pr merge 9')", "bash <(echo 'gh pr merge 9')",
                "bash -c \"$(echo 'gh pr merge 9')\"",
                "bash -c bash <<'EOF'\ngh pr merge 9\nEOF",
                "sh -c '. /dev/stdin' <<'EOF'\ngh pr merge 9\nEOF",
                'bash -c "$(cat)" <<\'EOF\'\ngh pr merge 9\nEOF'):
    assert not expect(command, 2)[0], command
assert not expect("cat < <(echo 'gh pr merge 9')", 0)[0]
assert not expect("bash -c 'cat -' <<'EOF'\ngh pr merge 9\nEOF", 0)[0]
seen, _ = expect("command -v gh >/dev/null && gh pr merge 7", 0)
assert seen, seen
for command in ("export HOME=/other; bash -c 'cd && gh pr merge 7'",
                "export CDPATH=/other; bash -c 'cd child && gh pr merge 7'",
                "HOME=/other bash -c 'cd && gh pr merge 7'",
                "sudo -H bash -c 'cd && gh pr merge 7'",
                "sudo -u other bash -c 'cd child && gh pr merge 7'"):
    assert not expect(command, 2)[0], command
    expect(command + " --repo o/r" if "bash" not in command else command.replace("merge 7", "merge 7 --repo o/r"), 0)
for command in (
    "eval cd child && gh pr merge 7 --repo o/r",
    "source change-dir.sh; gh pr merge 7 --repo o/r",
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash -c '. ./script.sh' ''',
    '''cat > script.sh <<'EOF'\ngh pr merge 9\nEOF\nbash -c 'source ./script.sh' ''',
    '''git -c core.pager='bash <&3' --paginate log -1 3<<< 'gh pr merge 9' ''',
    '''bash -s 3<<< 'gh pr merge 9' <<< 'git -c core.pager="bash <&3" --paginate log -1' ''',
    '''export MSG='gh pr merge 9'; python3 build.py''',
    '''MSG='gh pr merge 9' python3 build.py''',
    '''MSG='gh pr merge 9'; python3 -c "$MSG"''',
    '''MSG='gh pr merge 9'; eval "$MSG"''',
    '''MSG='gh pr merge 9'; printf '%s' "$MSG" | python3 -''',
    '''export GIT_EXTERNAL_DIFF; declare -n dest=GIT_EXTERNAL_DIFF; dest='gh pr merge 9'; git diff --ext-diff''',
    '''export $(printf '%s' 'GIT_EXTERNAL_DIFF=gh pr merge 9'); git diff --ext-diff''',
    '''CMD='gh pr merge 9'; $CMD''',
    '''CMD='gh pr merge 9'; env $CMD''',
    '''CMD='gh pr merge 9'; bash -c "$CMD"''',
    '''CMD='gh pr merge 9'; (eval "$CMD")''',
    '''CMD='gh pr merge 9'; git commit -m "$(eval "$CMD")"''',
    '''CMD='gh pr merge 9'; bash <<EOF\n$CMD\nEOF''',
    '''set -a; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''set -o allexport; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''setopt ALL_EXPORT; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''setopt -- allexport; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''unsetopt noallexport; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''set +o noallexport; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''set +o NO_ALL_EXPORT; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''printf '%s\\n' 'gh pr merge 9' > .zshenv; ZDOTDIR=. zsh -c true''',
    '''zsh -o interactive -c 'gh pr merge 9' ''',
    '''zsh -o login -c 'gh pr merge 9' ''',
    '''zsh -f -o interactive -c 'gh pr merge 9' ''',
    '''bash --posix -c 'GIT_EXTERNAL_DIFF="gh pr merge 9" export DUMMY; git diff --ext-diff' ''',
    '''bash --posix -c 'GIT_EXTERNAL_DIFF="gh pr merge 9" exec; git diff --ext-diff' ''',
    '''readonly -x GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''declare -i x='a[$(gh pr merge 9)]' ''',
    '''set -k; git diff --ext-diff GIT_EXTERNAL_DIFF='gh pr merge 9' ''',
    '''set -o keyword; git diff --ext-diff GIT_EXTERNAL_DIFF='gh pr merge 9' ''',
    '''bash -o keyword -c 'git diff --ext-diff GIT_EXTERNAL_DIFF="gh pr merge 9"' ''',
    '''f() { gh pr merge 9; }; f''',
    '''case x in (x) gh pr merge 9;; esac''',
    '''cat > s.sh <<'EOF'\ngh pr merge 9\nEOF\nBASH_ENV=./s.sh bash -c true''',
    '''cat > s.sh <<'EOF'\ngh pr merge 9\nEOF\nexport BASH_ENV=./s.sh; bash -c true''',
    '''cat > s.sh <<'EOF'\ngh pr merge 9\nEOF\nENV=./s.sh sh -ic true''',
    '''OPTIONS=-a; set "$OPTIONS"; GIT_EXTERNAL_DIFF='gh pr merge 9'; git diff --ext-diff''',
    '''bash -o allexport -c 'GIT_EXTERNAL_DIFF="gh pr merge 9"; git diff --ext-diff' ''',
    '''OPT=allexport; bash -o "$OPT" -c 'GIT_EXTERNAL_DIFF="gh pr merge 9"; git diff --ext-diff' ''',
    '''env SHELLOPTS=allexport bash -c 'GIT_EXTERNAL_DIFF="gh pr merge 9"; git diff --ext-diff' ''',
    '''(python3 -) <<'EOF'\nimport os; os.system("gh pr merge 9")\nEOF''',
    '''(xargs -I{} sh -c {}) <<< 'gh pr merge 9' ''',
    '''(git -c diff.external='bash <&3' diff --ext-diff) 3<<< 'gh pr merge 9' ''',
    '''bash -s -- gh pr merge 9 <<'EOF'\nexec "$@"\nEOF''',
):
    assert not expect(command, 2)[0], command
for command in ("printf '%s\\n' 'gh pr merge 9' | bash",
                "echo 'gh pr merge 9' | sh", "echo 'gh pr merge 9' | cat | bash",
                "cat <<'EOF' | bash\ngh pr merge 9\nEOF",
                "echo 'gh pr merge 9' | python3"):
    assert not expect(command, 2)[0], command
expect("bash <<< 'gh pr merge 9'", 2)
expect("cat <<EOF\n$(gh pr merge 9)\nEOF", 2)
expect("cat <<EOF\n`gh pr merge 9`\nEOF", 2)
expect("cat <(gh pr merge 9)", 2)
expect("bash -c 'curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge'", 2)
expect("export GH_REPO=other/repo; bash -c 'gh pr merge 7'", 2)
for declaration in ("declare -x", "typeset -x", "readonly"):
    expect(f"{declaration} GH_REPO=other/repo; gh pr merge 7", 2)
seen, _ = expect("cd -- child && gh pr merge 7", 0)
assert seen[0][1] == "/work/child", seen
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    work, child = root / "work", root / "other/repo/child"
    work.mkdir()
    child.mkdir(parents=True)
    (work / "link").symlink_to(child, target_is_directory=True)
    logical = subprocess.run(["bash", "--noprofile", "--norc", "-c", "cd link && cd .. && pwd -L"],
                             cwd=work, env={"PATH": os.environ["PATH"]}, text=True, capture_output=True, check=True).stdout.strip()
    seen, _ = expect("cd link && cd .. && gh pr merge 7", 0, cwd=str(work))
    assert seen[0][1] == logical == str(work), seen
    physical = subprocess.run(["bash", "--noprofile", "--norc", "-c", "cd .. && pwd -L"],
                              cwd=work / "link", env={"PATH": os.environ["PATH"]}, text=True, capture_output=True, check=True).stdout.strip()
    assert physical == str(child.parent)
    assert not expect("cd .. && gh pr merge 7", 2, cwd=str(work / "link"))[0]
    assert expect("cd .. && gh pr merge 7 --repo o/r", 0, cwd=str(work / "link"))[0]
    for prefix in ("set -P;", "set -o physical;", "shopt -s cdable_vars;"):
        command = f"{prefix} cd link && cd .. && gh pr merge 7"
        assert not expect(command, 2, cwd=str(work))[0]
        assert expect(command + " --repo o/r", 0, cwd=str(work))[0]
    for options in ("-P", "-o physical"):
        command = f"bash {options} -c 'cd link && cd .. && gh pr merge 7'"
        assert not expect(command, 2, cwd=str(work))[0]
        assert expect(command.replace("merge 7", "merge 7 --repo o/r"), 0, cwd=str(work))[0]
seen, _ = expect("cd child && gh pr merge 7 --squash | tee merge.log", 0)
assert seen[0][1] == "/work/child", seen
# After a semicolon the merge also runs when cd failed, so both directories
# remain possible even when the intervening pipeline contains no cd.
assert not expect("cd child && git log | head -1; gh pr merge 7", 2)[0]
for declaration in ("export", "declare -x", "typeset -x", "readonly"):
    for assignment, cd in (("CDPATH=/other", "cd child"), ("HOME=/other", "cd")):
        command = f"{declaration} {assignment}; {cd} && gh pr merge 7"
        assert not expect(command, 2)[0], command
        expect(command + " --repo o/r", 0)
for command in ("cd child | cat; gh pr merge 7", "cd child & gh pr merge 7"):
    assert not expect(command, 2)[0], command
seen, _ = expect("bash -c 'cd child && gh pr merge 7'; gh pr merge 7", 0)
assert [cwd for _, cwd in seen] == ["/work/child", "/work"], seen
seen, _ = expect("bash <<'EOF'\ncd child && gh pr merge 7\nEOF\ngh pr merge 7", 0)
assert [cwd for _, cwd in seen] == ["/work/child", "/work"], seen

# Request flags have client-specific meanings: curl -f is --fail and wget -d
# is --debug; neither consumes the following URL or body option.
for command in (
    "curl -f https://git.example/api/v1/repos/o/r/pulls/9/merge -X POST --json '{}'",
    "curl -X POST &>/dev/null https://git.example/api/v1/repos/o/r/pulls/9/merge",
    "curl -fsSXPOST https://git.example/api/v1/repos/o/r/pulls/9/merge --json '{}'",
    "wget -d https://git.example/api/v1/repos/o/r/pulls/9/merge --method POST --body-data '{}'",
):
    seen, _ = expect(command, 2)
    assert seen, command
expect("curl -f https://git.example/api/v1/repos/o/r/pulls/7/merge -X POST --json '{}'", 0)
for flags in ("--silent", "-m 30", "--max-time 30", "--connect-timeout 10 --retry 3"):
    seen, _ = expect(f"curl {flags} -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --json '{{}}'", 0)
    assert seen, flags
for command in (
    '''curl -f --json '{"merge_when_checks_succeed":true}' https://git.example/api/v1/repos/o/r/pulls/7/merge''',
    '''tea api -X POST /repos/o/r/pulls/7/merge --Field merge_when_checks_succeed=true''',
    '''tea api -X POST /repos/o/r/pulls/7/merge -F=merge_when_checks_succeed=true''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --data-urlencode merge_when_checks_succeed=true''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --form merge_when_checks_succeed=true''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --form-string merge_when_checks_succeed=true''',
    '''wget https://git.example/api/v1/repos/o/r/pulls/7/merge --post-data 'x=1&merge_when_checks_succeed=true' ''',
    '''wget https://git.example/api/v1/repos/o/r/pulls/7/merge --method POST --body-data 'merge_when_checks_succeed=true' ''',
    '''wget https://git.example/api/v1/repos/o/r/pulls/7/merge --post-file body.json''',
    '''wget https://git.example/api/v1/repos/o/r/pulls/7/merge --body-file body.json''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --upload-file body.json''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -Tbody.json''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --data-urlencode merge_when_checks_succeed@setting''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --config request.conf''',
    '''wget https://git.example/api/v1/repos/o/r/pulls/7/merge --config request.conf''',
    '''curl -X GET --config request.conf https://git.example/api/v1/repos/o/r/pulls/9/merge''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --data-ascii @body.json''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge --next -X GET https://example.org/''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge -: -X GET https://example.org/''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge https://git.example/api/v1/repos/o/r/pulls/9/merge''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --request-target=/api/v1/repos/o/r/pulls/9/merge''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --variable body@body.json --expand-data '{{body}}' ''',
    '''curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge --url @requests.txt --json '{}' ''',
    '''wget --method POST https://git.example/api/v1/repos/o/r/pulls/7/merge -i requests.txt''',
    '''curl -X POST https://git.example --request-target=/api/v1/repos/o/r/pulls/9/merge --json '{}' ''',
):
    assert not expect(command, 2)[0], command
seen, _ = expect("wget -H https://git.example/api/v1/repos/o/r/pulls/9/merge --method POST --body-data '{}'", 2)
assert seen, seen
expect("bash -s -- -c config <<'EOF'\ngh pr merge 9\nEOF", 2)
expect("bash -s arg -c config <<'EOF'\ngh pr merge 9\nEOF", 2)
seen, _ = expect("FOO=1 cd child && gh pr merge 7", 0)
assert seen[0][1] == "/work/child", seen
for command in ("{ cd child; } && gh pr merge 7", "! cd child && gh pr merge 7", "time cd child && gh pr merge 7",
                "pushd child && gh pr merge 7", "popd && gh pr merge 7", "HOME=elsewhere cd && gh pr merge 7",
                'gh pr merge "$PR"', 'gh pr merge "$(printf 9)"'):
    assert not expect(command, 2)[0], command
seen, _ = expect("curl --referer https://git.example/api/v1/repos/o/r/pulls/7/merge -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge", 2)
assert seen and seen[0][0].number == "9", seen

# gh pr merge resolves selector, repository and cwd for gh pr view.
seen, _ = expect("gh pr merge 5 --squash --body 'x y' -R owner/repo", 2)
assert seen[0][0][:6] == ["gh", "pr", "view", "5", "--repo", "owner/repo"], seen
seen, _ = expect("cd sub && gh pr merge 7 --squash", 0)
assert seen[0][1] == "/work/sub", seen
expect("gh pr merge --repo=owner/reviewed --squash", 0)
expect("gh pr merge 7 --body '--auto'", 0)
assert not expect("gh pr create --body 'repos/o/r/pulls/9/merge'", 0)[0]
assert not expect("curl https://example.com --data 'repos/o/r/pulls/9/merge'", 0)[0]

# A review of an earlier head does not count.
_, message = expect("gh pr merge 9 --squash", 2)
assert f"current head {HEAD[:12]}" in message, message

# GitHub API and Forgejo REST merges.
expect("gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash", 0)
expect("gh api -X PUT repos/o/r/pulls/8/merge", 2)
seen, _ = expect("curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -d '{}'", 0)
assert seen[0][0].host == "https://git.example", seen
expect("curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge", 2)
expect('curl -X POST "$FORGEJO/api/v1/repos/o/r/pulls/8/merge"', 2)
expect("curl --request GET https://git.example/api/v1/repos/o/r/pulls/8/merge", 0)

# tea and fj merge commands are refused and point to the MCP tool or tea api (#616).
seen, _ = expect("gh pr merge 9 --squash 2>&1 | tail -3", 2)
assert seen[0][0][3] == "9", seen
expect("gh pr merge 7 --squash >/dev/null", 0)
for command in ("tea pulls merge --repo o/r 7", "tea pr m -r o/r 7", "tea pulls --fields index merge --repo o/r 7",
                "fj pr merge o/r#7", "fj -H git.alc.xyz pr merge --method=squash o/r#7"):
    calls.clear()
    code, message = hook(command)
    assert code == 2 and "merge_pull_request" in message and not calls, (command, message)
# A refused merge blocks the whole command, and reads are not merges.
expect("gh pr merge 7 --squash && tea pulls merge --repo o/r 7", 2)
assert not expect("fj pr view o/r#7", 0)[0]
assert not expect("tea pulls list --repo o/r", 0)[0]
assert not expect("echo fj; tea issues ls", 0)[0]
# tea api merges are REST merges, checked on the configured instance.
seen, _ = expect("""tea api -X POST /repos/o/r/pulls/7/merge -d '{"Do": "squash"}'""", 0)
assert seen[0][0].host == review.FORGEJO_URL, seen
expect("tea api -X POST /repos/o/r/pulls/9/merge", 2)


# Forgejo MCP tools other than merges pass without lookups (ADR-0081).
def mcp_hook(tool, tool_input=None):
    tool_input = {"owner": "o", "repo": "r", "index": 7} if tool_input is None else tool_input
    sys.stdin = io.StringIO(json.dumps({"tool_name": tool, "tool_input": tool_input}))
    sys.stderr = io.StringIO()
    try:
        return review.main(["guard"]), sys.stderr.getvalue()
    finally:
        sys.stdin, sys.stderr = sys.__stdin__, sys.__stderr__


calls.clear()
for tool in ("get_issue_by_index", "create_issue_comment", "dispatch_workflow", "delete_branch"):
    assert mcp_hook(f"mcp__forgejo__{tool}") == (0, ""), tool
assert mcp_hook("mcp__other__merge_pull_request")[0] == 0
assert not calls, calls

# An MCP merge is verified like other merges, on the MCP server's instance.
with tempfile.TemporaryDirectory() as state:
    os.environ["AGENT_MCP_STATE_DIR"] = state
    for client in ("codex", "claude"):
        pathlib.Path(state, f"{client}-managed.json").write_text(json.dumps({"managed": ["forgejo"]}))
    merge = "mcp__forgejo__merge_pull_request"
    calls.clear()
    code, message = mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "squash", "title": "t"})
    assert code == 0, message
    assert (calls[0][0].host, calls[0][0].owner, calls[0][0].repo, calls[0][0].number) == (
        review.FORGEJO_MCP_URL, "o", "r", "7"), calls
    assert mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7.0, "style": "merge"})[0] == 0
    code, message = mcp_hook(merge, {"owner": "o", "repo": "r", "index": 9, "style": "squash"})
    assert code == 2 and f"current head {HEAD[:12]}" in message and "pr-review run <pr>" in message, message
    for arguments, hint in (
        ({"owner": "o", "repo": "r", "index": 7, "style": "squash", "force_merge": True}, "force_merge"),
        ({"owner": "o", "repo": "r", "index": 7, "style": "squash", "merge_when_checks_succeed": True},
         "merge_when_checks_succeed"),
        ({"owner": "..", "repo": "r", "index": 7, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r/x", "index": 7, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": "7", "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": True, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": 7.5, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": 7, "style": "squash", "auto_merge": True}, "unexpected arguments auto_merge"),
        ([], "no arguments"),
    ):
        calls.clear()
        code, message = mcp_hook(merge, arguments)
        assert code == 2 and hint in message and not calls, (arguments, message)
    assert mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "squash", "force_merge": False,
                            "merge_when_checks_succeed": False, "delete_branch_after_merge": True})[0] == 0
    # A `forgejo` server that programs.ai does not manage for either client may
    # point elsewhere: MCP merges are refused.
    reviewed = {"owner": "o", "repo": "r", "index": 7, "style": "squash"}
    claude_state = pathlib.Path(state, "claude-managed.json")
    for content in (json.dumps({"managed": []}), "{not json", json.dumps({"managed": "forgejo"}), None):
        if content is None:
            claude_state.unlink()
        else:
            claude_state.write_text(content)
        calls.clear()
        code, message = mcp_hook(merge, reviewed)
        assert code == 2 and "not the one programs.ai manages" in message and not calls, (content, message)
    claude_state.write_text(json.dumps({"managed": ["forgejo"]}))
    assert mcp_hook(merge, reviewed)[0] == 0
    # The lookup only covers the guard's own instance.
    review.FORGEJO_MCP_URL = "https://other.example"
    code, message = mcp_hook(merge, reviewed)
    assert code == 2 and "only when the server uses" in message, message
    review.FORGEJO_MCP_URL = review.FORGEJO_URL
    del os.environ["AGENT_MCP_STATE_DIR"]
# Without the registration state, MCP merges are refused.
code, message = mcp_hook("mcp__forgejo__merge_pull_request", {"owner": "o", "repo": "r", "index": 7})
assert code == 2 and "not the one programs.ai manages" in message, message

# Fast-forward repositories (ADR-0078): only Forgejo merges into the listed
# repositories must be fast-forward-only, without leftover fixups or commits by
# agent identities. Other repositories and GitHub keep the review check alone.
commit_pages = {}


def commits_forgejo(pr, path, data=None, accept="application/json"):
    if path.startswith(f"pulls/{pr.number}/commits?"):
        calls.append((pr, path))
        assert "limit=50" in path, path
        return commit_pages.get(int(re.search(r"[?&]page=(\d+)", path)[1]), [])
    return fake_forgejo(pr, path, data, accept)


def pr_commit(subject, author="operator@example.invalid", committer="operator@example.invalid"):
    return {"sha": "a" * 40, "commit": {"message": f"{subject}\n\nbody\n", "author": {"email": author},
                                        "committer": {"email": committer}}}


review.forgejo_request = commits_forgejo
with tempfile.TemporaryDirectory() as tmp:
    os.environ["PR_REVIEW_CONFIG"] = os.path.join(tmp, "config.json")
    forgejo_host = urllib.parse.urlparse(review.FORGEJO_URL).netloc
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps({
        "reviewers": [], "fast_forward_repositories": [f"{forgejo_host}/O/r"],
        "agent_identities": ["Agent@example.invalid"]}))
    commit_pages.update({1: [pr_commit("feat: one")], 2: [pr_commit("fix: two")]})
    rest = "tea api -X POST /repos/o/r/pulls/7/merge "
    fast_forward = '''-d '{"Do":"fast-forward-only"}' '''
    for payload in ('''-d '{"Do":"squash"}' ''', '''-d '{"Do":"merge"}' ''', "", "-f Do=rebase",
                    '''-d '{"Do":"fast-forward-only","do":"squash"}' '''):
        calls.clear()
        code, message = hook(rest + payload)
        assert code == 2 and "fast-forward repository" in message and "fast-forward-only" in message, (payload, message)
    seen, _ = expect(rest + fast_forward, 0)
    assert [path for _, path in seen if "commits" in path] == [
        f"pulls/7/commits?limit=50&page={page}&verification=false&files=false" for page in (1, 2, 3)], seen
    expect(rest + "-f Do=fast-forward-only", 0)
    expect(f'''curl -X POST {review.FORGEJO_URL}/api/v1/repos/o/r/pulls/7/merge -d '{{"do":"fast-forward-only"}}' ''', 0)
    # Leftover fix rounds, also on a later page, must be folded first.
    for subject in ("fixup! feat: one", "squash! feat: one", "amend! feat: one"):
        commit_pages[2] = [pr_commit(subject)]
        code, message = hook(rest + fast_forward)
        assert code == 2 and "still has the commit" in message and "--autosquash" in message, (subject, message)
    # A commit by an agent forge account, as after a forge-side rebase or branch update.
    for commit in (pr_commit("fix: two", committer="agent@example.invalid"),
                   pr_commit("fix: two", author="AGENT@example.invalid")):
        commit_pages[2] = [commit]
        code, message = hook(rest + fast_forward)
        assert code == 2 and "agent forge account" in message, message
    # The review is still required.
    commit_pages[2] = [pr_commit("fix: two")]
    code, message = hook("tea api -X POST /repos/o/r/pulls/9/merge " + fast_forward)
    assert code == 2 and f"current head {HEAD[:12]}" in message, message
    # Unlisted repositories and GitHub merges are unchanged and never list commits.
    commit_pages[2] = [pr_commit("fixup! feat: one", committer="agent@example.invalid")]
    for command in ('''tea api -X POST /repos/o/other/pulls/7/merge -d '{"Do":"squash"}' ''',
                    "gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash", "gh pr merge 7 --squash"):
        seen, _ = expect(command, 0)
        assert not any("commits" in str(call) for call in seen), (command, seen)
    # MCP merges follow the same rule through their `style`.
    with tempfile.TemporaryDirectory() as state:
        os.environ["AGENT_MCP_STATE_DIR"] = state
        for client in ("codex", "claude"):
            pathlib.Path(state, f"{client}-managed.json").write_text(json.dumps({"managed": ["forgejo"]}))
        merge = "mcp__forgejo__merge_pull_request"
        code, message = mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "fast-forward-only"})
        assert code == 2 and "still has the commit" in message, message
        commit_pages[2] = [pr_commit("fix: two")]
        assert mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "fast-forward-only"})[0] == 0
        code, message = mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "squash"})
        assert code == 2 and "fast-forward repository" in message, message
        assert mcp_hook(merge, {"owner": "o", "repo": "other", "index": 7, "style": "squash"})[0] == 0
        del os.environ["AGENT_MCP_STATE_DIR"]
    del os.environ["PR_REVIEW_CONFIG"]
review.forgejo_request = fake_forgejo

# GitHub fast-forward repositories (ADR-0078): agents merge by pushing the
# reviewed head to the base branch. The agent pre-push hook (`pr-review
# pre-push`) checks what Git pushes; the PreToolUse guard refuses GitHub-side
# merges, API ref writes and literal attempts to skip the hook. Other
# repositories, hosts and Forgejo stay unaffected and never call GitHub.
github_pulls, github_bodies, github_commits, github_failures = {}, {}, {}, []
ZERO = "0" * 40


def github_response(endpoint):
    """Answer a faked `gh api` call for o/r, or None for other endpoints."""
    path, _, query = endpoint.partition("?")
    parts, fields = path.split("/"), dict(urllib.parse.parse_qsl(query))
    rest = "/".join(parts[3:])
    if "/".join(parts[1:3]).lower() != "o/r" or not (
            rest in ("", "pulls") or re.fullmatch(r"pulls/1\d/commits|issues/1\d/comments", rest)):
        return None
    if github_failures:
        raise review.ReviewError("gh api failed: offline")
    if rest == "":
        return json.dumps({"default_branch": "dev"})
    if rest == "pulls":
        assert fields["state"] == "open" and fields["per_page"] == "100" and fields["page"] == "1", endpoint
        return json.dumps([pull for pull in github_pulls.values() if pull["base"]["ref"] == fields["base"]])
    number = parts[4]
    if rest.endswith("/commits"):
        assert fields["per_page"] == "100" and fields["page"] == "1", endpoint
        return json.dumps(github_commits.get(number, []))
    return "\n".join(json.dumps(body) for body in github_bodies.get(number, []))


def github_run(argv, cwd=None, stdin=None, timeout=None):
    if argv[0] == "git":
        return real_run(argv, cwd, stdin, timeout)
    endpoint = argv[4] if argv[:4] == ["gh", "api", "--hostname", "github.com"] else ""
    if github_response(endpoint) is None:
        return fake_run(argv, cwd, stdin, timeout)
    calls.append((argv, cwd))
    return github_response(endpoint)


def gh_calls(seen):
    return [call[0][4] for call in seen if call[0][:2] == ["gh", "api"]]


review.run = github_run
with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull,
                                                                  "GIT_CONFIG_NOSYSTEM": "1"}):
    # The hook checks only agent processes; start without any marker.
    for marker in ("CLAUDECODE", "PR_REVIEW_AGENT_SESSION", *review.CODEX_MARKERS):
        os.environ.pop(marker, None)
    os.environ["PR_REVIEW_CONFIG"] = os.path.join(tmp, "config.json")
    forgejo_host = urllib.parse.urlparse(review.FORGEJO_URL).netloc

    def configure(*repositories):
        pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps({
            "reviewers": [], "fast_forward_repositories": list(repositories),
            "agent_identities": ["agent@example.invalid"]}))

    repo = os.path.join(tmp, "repo")

    def git(*args, cwd=repo, env=None):
        return subprocess.run(["git", "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                               "-c", "commit.gpgsign=false", *args], cwd=cwd, check=True, env=env,
                              capture_output=True, text=True).stdout.strip()

    os.makedirs(repo)
    git("init", "-q", "-b", "main")
    git("commit", "-q", "--allow-empty", "-m", "init")
    base = git("rev-parse", "HEAD")
    git("branch", "dev")
    heads = {}
    for branch in ("feature", "unreviewed", "loose", "side"):
        git("switch", "-q", "-c", branch, "main")
        git("commit", "-q", "--allow-empty", "-m", f"feat: {branch}")
        heads[branch] = git("rev-parse", "HEAD")
    git("switch", "-q", "feature")
    reviewed = heads["feature"]
    github_pulls.update({
        "17": {"number": 17, "head": {"sha": reviewed}, "base": {"ref": "dev"}},
        "19": {"number": 19, "head": {"sha": heads["unreviewed"]}, "base": {"ref": "dev"}},
    })
    github_bodies.update({
        "17": [f"Automated read-only review ({reviewed[:12]} on dev): no blocking findings."],
        "19": [f"Automated read-only review ({reviewed[:12]} on dev): no blocking findings."],
    })
    github_commits.update({"17": [pr_commit("feat: feature")], "19": [pr_commit("feat: unreviewed")]})
    configure("github.com/O/R", f"{forgejo_host}/O/r")
    listed_url = "https://github.com/O/R.git"

    def pre_push(url, *lines):
        calls.clear()
        sys.stdin, sys.stderr = io.StringIO("".join(f"{line}\n" for line in lines)), io.StringIO()
        previous = os.getcwd()
        os.chdir(repo)
        try:
            return review.main(["pre-push", "origin", url]), sys.stderr.getvalue(), gh_calls(calls)
        finally:
            os.chdir(previous)
            sys.stdin, sys.stderr = sys.__stdin__, sys.__stderr__

    def update(local, remote_ref="refs/heads/dev", remote=base):
        return f"refs/heads/x {local} {remote_ref} {remote}"

    # The operator's own pushes are never checked: without an agent marker the
    # hook returns before reading configuration or calling GitHub.
    configured = os.environ["PR_REVIEW_CONFIG"]
    os.environ["PR_REVIEW_CONFIG"] = os.path.join(tmp, "missing.json")
    code, _, seen = pre_push(listed_url, update(ZERO))
    assert code == 0 and not seen, seen
    os.environ["PR_REVIEW_CONFIG"] = configured
    for marker, value in (("CLAUDECODE", "1"), ("PR_REVIEW_AGENT_SESSION", "1"), ("CODEX_THREAD_ID", "t"),
                          ("CODEX_TOOL_CALL_ID", "c"), ("CODEX_SANDBOX_NETWORK_DISABLED", "1")):
        with patch.dict(os.environ, {marker: value}):
            assert pre_push(listed_url, update(ZERO))[0] == 1, marker
    with patch.dict(os.environ, {"CLAUDECODE": "0", "PR_REVIEW_AGENT_SESSION": ""}):
        assert pre_push(listed_url, update(ZERO))[0] == 0
    os.environ["PR_REVIEW_AGENT_SESSION"] = "1"

    # The reviewed head of an open PR may fast-forward its base, by any GitHub URL form.
    for url in (listed_url, "git@github.com:O/R.git", "git@github.com:/O/R.git", "ssh://git@github.com/o/r",
                "https://GITHUB.COM:443/O/R", "ssh://git@ssh.github.com:443/O/R.git"):
        code, message, seen = pre_push(url, update(reviewed))
        assert code == 0 and "repos/O/R/pulls/17/commits?per_page=100&page=1" in [path.replace("o/r", "O/R") for path in seen], (url, message, seen)
    assert pre_push(listed_url, update(reviewed, remote=ZERO))[0] == 0  # creating the base
    # Other updates of a protected branch are refused.
    for line, hint in (
        (update(heads["unreviewed"]), f"no automated review comment for its current head {heads['unreviewed'][:12]}"),
        (update(heads["loose"]), "is not the head of an open PR into dev"),
        (update(reviewed, "refs/heads/main"), "is not the head of an open PR into main"),
        (update(ZERO), "deleting its protected branch dev"),
        (update(reviewed, remote=heads["side"]), "does not fast-forward"),
        (update(reviewed, remote="1" * 40), "which this clone does not have"),
        ("refs/heads/x HEAD refs/heads/dev", "unexpected pre-push input"),
    ):
        code, message, _ = pre_push(listed_url, line)
        assert code == 1 and hint in message and "pr-review run <pr>" in message, (line, message)
    for commit, hint in ((pr_commit("fixup! feat: feature"), "still has the commit"),
                         (pr_commit("fix: two", committer="Agent@example.invalid"), "agent forge account")):
        github_commits["17"] = [pr_commit("feat: feature"), commit]
        code, message, _ = pre_push(listed_url, update(reviewed))
        assert code == 1 and hint in message, message
    github_commits["17"] = [pr_commit("feat: feature")]
    # Several open PRs with that head into the base: one that passes is enough.
    pulls = dict(github_pulls)
    github_pulls.clear()
    github_pulls.update({"16": {"number": 16, "head": {"sha": reviewed}, "base": {"ref": "dev"}}, **pulls})
    github_bodies["16"] = []
    github_commits["16"] = [pr_commit("fixup! feat: feature")]
    code, message, seen = pre_push(listed_url, update(reviewed))
    assert code == 0 and "repos/O/R/pulls/17/commits?per_page=100&page=1" in seen, (message, seen)
    github_commits["17"] = [pr_commit("fixup! feat: feature")]
    code, message, _ = pre_push(listed_url, update(reviewed))
    assert code == 1 and "O/R#16 has no automated review comment" in message, message
    github_commits["17"] = [pr_commit("feat: feature")]
    github_pulls.clear()
    github_pulls.update(pulls)
    # One refused line refuses the whole push.
    assert pre_push(listed_url, update(reviewed, "refs/heads/topic", ZERO), update(heads["loose"]))[0] == 1
    # Feature branches pass after learning they are not protected; tags pass without lookups.
    code, _, seen = pre_push(listed_url, update(heads["loose"], "refs/heads/topic", heads["side"]))
    assert code == 0 and seen == ["repos/O/R", "repos/O/R/pulls?state=open&base=topic&per_page=100&page=1"], seen
    code, _, seen = pre_push(listed_url, update(heads["loose"], "refs/tags/v1", ZERO), update(ZERO, "refs/tags/v0"))
    assert code == 0 and not seen, seen
    # Unlisted repositories and other hosts pass without lookups, even unreadable configuration
    # for hosts that are not GitHub.
    for url in ("git@github.com:o/other.git", f"ssh://git@{forgejo_host}/O/r.git", "/srv/git/repo.git",
                "https://gitlab.com/O/R.git"):
        code, _, seen = pre_push(url, update(ZERO))
        assert code == 0 and not seen, (url, seen)
    configured = os.environ["PR_REVIEW_CONFIG"]
    os.environ["PR_REVIEW_CONFIG"] = os.path.join(tmp, "missing.json")
    assert pre_push(f"ssh://git@{forgejo_host}/O/r.git", update(ZERO))[0] == 0
    code, message, _ = pre_push(listed_url, update(reviewed))
    assert code == 1 and "missing.json" in message, message
    os.environ["PR_REVIEW_CONFIG"] = configured
    # Lookup failures refuse pushes to listed repositories.
    github_failures.append(True)
    code, message, _ = pre_push(listed_url, update(reviewed))
    assert code == 1 and "offline" in message, message
    github_failures.clear()

    # End to end: Git runs the hook from its environment configuration, as T3
    # agent sessions register it, with a fake gh serving the same answers.
    bin_dir = os.path.join(tmp, "bin")
    os.makedirs(bin_dir)
    fixtures = os.path.join(tmp, "gh.json")
    fake_gh = pathlib.Path(bin_dir, "gh")
    fake_gh.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        "answers = json.load(open(os.environ['FAKE_GH_ANSWERS']))\n"
        "endpoint = sys.argv[4] if sys.argv[1:4] == ['api', '--hostname', 'github.com'] else ''\n"
        "if endpoint not in answers:\n"
        "    sys.exit(f'unexpected gh call {sys.argv[1:]}')\n"
        "print(answers[endpoint])\n")
    fake_gh.chmod(0o755)
    endpoints = ["repos/O/R", "repos/O/R/pulls?state=open&base=dev&per_page=100&page=1",
                 "repos/O/R/pulls/17/commits?per_page=100&page=1", "repos/O/R/issues/17/comments",
                 "repos/O/R/issues/19/comments", "repos/O/R/pulls/19/commits?per_page=100&page=1",
                 "repos/O/R/pulls?state=open&base=topic&per_page=100&page=1"]
    pathlib.Path(fixtures).write_text(json.dumps({endpoint: github_response(endpoint) for endpoint in endpoints}))
    # As Home Manager registers it: in the user's global Git configuration.
    global_config = os.path.join(tmp, "gitconfig")
    pathlib.Path(global_config).write_text(
        '[hook "agent-pr-review"]\n'
        f'\tcommand = "{sys.executable} {ROOT}/modules/home-manager/programs/ai/pr-review.py pre-push"\n'
        "\tevent = pre-push\n")
    hook_env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "FAKE_GH_ANSWERS": fixtures,
                "GIT_CONFIG_GLOBAL": global_config}
    assert "agent-pr-review" in git("hook", "list", "pre-push", env=hook_env)

    def run_hook(line, url=listed_url):
        stdin = os.path.join(tmp, "pre-push.in")
        pathlib.Path(stdin).write_text(line + "\n")
        return subprocess.run(["git", "hook", "run", f"--to-stdin={stdin}", "pre-push", "--", "origin", url],
                              cwd=repo, env=hook_env, capture_output=True, text=True)

    result = run_hook(update(reviewed))
    assert result.returncode == 0, result.stderr
    result = run_hook(update(heads["unreviewed"]))
    assert result.returncode != 0 and "Blocked by the agent PR review pre-push hook" in result.stderr, result.stderr
    assert "current head" in result.stderr, result.stderr
    # The operator's own push, without an agent marker, is not checked; and a
    # command-line override of `hook.<name>.enabled` disables the hook, which
    # is why the PreToolUse guard refuses it.
    hook_env["PR_REVIEW_AGENT_SESSION"] = ""
    assert run_hook(update(heads["unreviewed"])).returncode == 0
    hook_env["PR_REVIEW_AGENT_SESSION"] = "1"
    hook_env.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "hook.agent-pr-review.enabled",
                     "GIT_CONFIG_VALUE_0": "false"})
    assert run_hook(update(heads["unreviewed"])).returncode == 0
    del hook_env["GIT_CONFIG_COUNT"], hook_env["GIT_CONFIG_KEY_0"], hook_env["GIT_CONFIG_VALUE_0"]
    # A real push through the hook: a local repository is not GitHub, so it passes.
    bare = os.path.join(tmp, "bare.git")
    git("init", "-q", "--bare", bare, cwd=tmp)
    pushed = subprocess.run(["git", "push", "-q", bare, "feature:dev", "loose:topic"], cwd=repo, env=hook_env,
                            capture_output=True, text=True)
    assert pushed.returncode == 0, pushed.stderr
    assert git("rev-parse", "dev", cwd=bare) == reviewed

    # The PreToolUse guard leaves pushes to the hook, and reads parsed words,
    # so text in messages, reads of hook settings and unrelated options pass ...
    for command in ("git push origin +feature:dev", "git push origin :main", "bash -c 'git push --force origin dev'",
                    "git commit --no-verify -m x && git push origin feature",
                    "git commit -m 'git push --no-verify' && git push", "echo GIT_CONFIG_COUNT",
                    "git log --grep push", "git commit -m 'agent-job: forward GIT_CONFIG_COUNT' && git push",
                    "git config --get hook.agent-pr-review.command && git push",
                    "git config get hook.agent-pr-review.enabled", "git config --get-all --show-origin hook.x.event",
                    "git config --global --file=f --type bool --get hook.x.enabled",
                    "git config -z --get-regexp '^hook\\.' pre", "git config list --show-scope --includes",
                    "git config -f f -l", "git config get --default no --type=bool hook.x.enabled",
                    "git config --list --show-origin && git push", "docker run --env A=1 -i img && git push",
                    "GIT_CONFIG_COUNT=0 git status", "cat <<'EOF'\nGIT_CONFIG_COUNT=0 git push --no-verify\nEOF",
                    "git commit -m 'set hook.agent-pr-review.enabled' && git push"):
        assert not expect(command, 0, repo)[0], command
    # ... but refuses attempts to change or skip it.
    for command, hint in (
        ("git push --no-verify origin feature:dev", "--no-verify"),
        ("git push --no-ver origin feature:dev", "--no-verify"),
        ("git -C repo push -u --no-verify origin feature", "--no-verify"),
        ("xargs git push --no-verify origin <<< x", "run through xargs"),
        ("git commit -m $'x' && git push --no-verify", "cannot verify this command's Git hook settings"),
        ("git -c hook.agent-pr-review.command=true push origin feature:dev", "git -c hook.agent-pr-review.command"),
        ("git '-c' hook.agent-pr-review.command=true push origin HEAD:main", "git -c hook.agent-pr-review.command"),
        ("git -c hook.agent-pr-review.enabled=false push origin HEAD:main", "hook.agent-pr-review.enabled"),
        ("git --config-env=hook.agent-pr-review.enabled=OFF push", "hook.agent-pr-review.enabled"),
        ("git -c Hook.Agent-PR-Review.Enabled=false status", "Hook.Agent-PR-Review.Enabled"),
        ("git config hook.agent-pr-review.enabled false", "must not write"),
        ("git config --global hook.agent-pr-review.command true", "must not write"),
        ("git config --worktree --unset hook.agent-pr-review.command", "must not write"),
        ("git config --file .git/config --add hook.agent-pr-review.event pre-commit", "must not write"),
        ("git config set hook.agent-pr-review.enabled false", "must not write"),
        ("git config unset --global hook.agent-pr-review.command", "must not write"),
        ("git config --remove-section hook.agent-pr-review", "must not write"),
        ("git config remove-section hook.agent-pr-review", "must not write"),
        # Subcommand forms with options that take a value.
        ("git config set --file .git/config hook.agent-pr-review.enabled false", "must not write"),
        ("git config set --type bool --comment why hook.agent-pr-review.enabled false", "must not write"),
        ("git config set --global --value=pre-push hook.agent-pr-review.event pre-commit", "must not write"),
        ("git config set --value pre-push hook.agent-pr-review.event pre-commit", "must not write"),
        ("git config unset --file f hook.agent-pr-review.command", "must not write"),
        ("git config unset --worktree --all hook.agent-pr-review.event", "must not write"),
        ("git config set --system -- hook.agent-pr-review.enabled false", "must not write"),
        ("git config rename-section --file f hook.agent-pr-review other", "must not write"),
        # A rename into hook.* writes hook settings too.
        ("git config rename-section --file f staged hook.agent-pr-review", "must not write"),
        ("git config rename-section staged hook", "must not write"),
        ("git config --rename-section staged hook.agent-pr-review", "must not write"),
        ("git config --rename-section --local staged hook.agent-pr-review", "must not write"),
        ("git config --rename-section --file .git/config staged hook.agent-pr-review", "must not write"),
        ("git config set -t bool hook.agent-pr-review.enabled false", "must not write"),
        ("git config -t bool hook.agent-pr-review.enabled false", "must not write"),
        # Long options Git accepts abbreviated.
        ("git config --fil .git/config hook.agent-pr-review.enabled false", "must not write"),
        ("git config --rename-sec --loc staged hook.agent-pr-review", "must not write"),
        ("git config set --typ bool hook.agent-pr-review.enabled false", "must not write"),
        ("git config --remove-sec hook.agent-pr-review", "must not write"),
        # Unparsable text that clears a marker before a push.
        ("printf $'x'; unset CLAUDECODE; git push origin HEAD:main", "Git hook settings"),
        ("git config remove-section --local hook.agent-pr-review", "must not write"),
        ("git config --file f --type bool hook.agent-pr-review.enabled false", "must not write"),
        # The agent markers turn the hook on.
        ("CLAUDECODE= git push origin feature:dev", "CLAUDECODE"),
        ("unset PR_REVIEW_AGENT_SESSION; git push", "PR_REVIEW_AGENT_SESSION"),
        ("env -u CLAUDECODE -u PR_REVIEW_AGENT_SESSION git push", "CLAUDECODE"),
        ("export CODEX_THREAD_ID= && git push", "CODEX_THREAD_ID"),
        # Only strict read shapes are reads; anything else naming hook settings is refused.
        ("git config hook.agent-pr-review.command", "must not write"),
        ("git config --comment --get hook.agent-pr-review.enabled false", "must not write"),
        ("git config --comm x --get hook.agent-pr-review.enabled", "must not write"),
        ("git config --fil f --get hook.agent-pr-review.enabled", "must not write"),
        ("git config --get hook.agent-pr-review.enabled a b", "must not write"),
        ("git config get --value v hook.agent-pr-review.enabled", "must not write"),
        ("git config --get --unset hook.agent-pr-review.enabled", "must not write"),
        ("git config --list hook.agent-pr-review.enabled", "must not write"),
        # env -S splits a string into the command the guard does not read.
        ("env -S 'git push --force origin dev' true; git push", "env -S"),
        ("env --split=x git push", "env -S"),
        ("env -iS x git push", "clear the environment"),
        # eval through builtin or command wrappers is read like eval.
        ("builtin eval 'git push --no-verify origin feature:dev'", "--no-verify"),
        ("command eval 'git -c hook.agent-pr-review.enabled=false push'", "hook.agent-pr-review.enabled"),
        ("command -p eval 'git push --no-verify'", "--no-verify"),
        # env behind any wrapper, with any option the guard does not know.
        ("command env -S '-u PR_REVIEW_AGENT_SESSION git push origin HEAD:main'", "env -S"),
        ("exec env -S 'git push origin HEAD:main'", "env -S"),
        ("nohup env -S '-u PR_REVIEW_AGENT_SESSION git push origin HEAD:main'", "env -S"),
        ('command env -iu PR_REVIEW_AGENT_SESSION PATH="$PATH" git push origin HEAD:main', "env -iu"),
        ("sudo -E env --unset=CLAUDECODE git push", "CLAUDECODE"),
        ("timeout 60 nice env -u PR_REVIEW_AGENT_SESSION git push", "PR_REVIEW_AGENT_SESSION"),
        ("setsid env --frobnicate git push", "env --frobnicate"),
        # env assignments of hook-relevant variables, and a lone - after --.
        ("command env CLAUDECODE= git push origin HEAD:main", "CLAUDECODE"),
        ("nohup env -C /tmp GIT_DIR=/x/.git git push", "GIT_DIR"),
        ("env -0 GIT_CONFIG_COUNT=0 git push", "GIT_CONFIG_COUNT"),
        ("sudo env HOME=/tmp git push", "HOME"),
        ("env -- - git push", "env -"),
        ("command env -v -- - PATH=/usr/bin git push", "env -"),
        ("env --split-s='git push' true && git push", "env -S"),
        # Any hook word in a git config that is not a pure read, however options are abbreviated.
        ("git config rename-section --f f other hook", "must not write"),
        ("git config rename-section --fi=f hook.agent-pr-review other", "must not write"),
        ("git config --f=f --rename-section other HOOK", "must not write"),
        ("git config set --comm why hook.agent-pr-review.enabled false", "must not write"),
        ("git config --file=f --add hook.agent-pr-review.event pre-commit", "must not write"),
        # Include settings can change the hook too.
        ("git config --global include.path ~/elsewhere.inc", "must not write"),
        ("git config set includeIf.gitdir:~/x/.path f", "must not write"),
        ("git -c include.path=/tmp/x.inc push origin feature:dev", "include configuration"),
        ("git -c includeIf.gitdir:/.path=/tmp/x.inc push", "include configuration"),
        ("git --config-env=include.path=INC push", "include configuration"),
        # Bundled env options.
        ("env -iu HOME git push", "HOME"),
        ("env -i0 git push", "clear the environment"),
        ("env -uCLAUDECODE git push", "CLAUDECODE"),
        ("env -0u PR_REVIEW_AGENT_SESSION git push", "PR_REVIEW_AGENT_SESSION"),
        ("env --ignore-env git push", "clear the environment"),
        ("env --uns=GIT_CONFIG_GLOBAL git push", "GIT_CONFIG_GLOBAL"),
        # eval and expanding stdin are read as scripts.
        ("eval 'git push --no-verify origin feature:dev'", "--no-verify"),
        ("eval git -c hook.agent-pr-review.enabled=false push", "hook.agent-pr-review.enabled"),
        ('bash <<EOF\necho "$USER"\ngit push --no-verify origin feature:dev\nEOF', "--no-verify"),
        ('bash <<EOF\nunset PR_REVIEW_AGENT_SESSION\ngit push origin "$BRANCH"\nEOF', "PR_REVIEW_AGENT_SESSION"),
        ('sh <<< "HOME=/tmp git push origin $BRANCH"', "HOME"),
        ("export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.agent-pr-review.enabled GIT_CONFIG_VALUE_0=false",
         "GIT_CONFIG_KEY_0 must not set"),
        ("GIT_CONFIG_PARAMETERS=\"'hook.agent-pr-review.enabled=false'\" git status", "GIT_CONFIG_PARAMETERS"),
        ("GIT_CONFIG_COUNT=0 git push origin feature:dev", "GIT_CONFIG_COUNT"),
        ("unset GIT_CONFIG_COUNT; git push", "GIT_CONFIG_COUNT"),
        ("env -u GIT_CONFIG_KEY_0 git push", "GIT_CONFIG_KEY_0"),
        ("export GIT_CONFIG_PARAMETERS=x; git push", "GIT_CONFIG_PARAMETERS"),
        ("GIT_CONFIG_GLOBAL=/dev/null git push", "GIT_CONFIG_GLOBAL"),
        ("GIT_CONFIG_NOSYSTEM=1 git push", "GIT_CONFIG_NOSYSTEM"),
        ("HOME=/tmp git push origin feature:dev", "HOME"),
        ("export XDG_CONFIG_HOME=/tmp/x && git push", "XDG_CONFIG_HOME"),
        ('env -i PATH="$PATH" git push origin feature:dev', "clear the environment"),
        ("bash -c 'HOME=/tmp git push'", "HOME"),
    ):
        seen, message = expect(command, 2, repo)
        assert hint in message and not seen, (command, message)
    # GitHub-side merges, the merges API and ref updates through the API are refused.
    seen, message = expect("gh pr merge 7 --squash", 2, repo)
    assert f"git push <remote> {HEAD}:dev" in message and "fast-forward repository on GitHub" in message, message
    for command, hint in (
        ("gh pr merge 7 --rebase", "fast-forward repository on GitHub"),
        ("gh pr merge 7 --merge --repo o/r", "fast-forward repository on GitHub"),
        ("gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=merge", "fast-forward repository on GitHub"),
        ("curl -X PUT https://API.github.com/repos/O/R/pulls/7/merge", "fast-forward repository on GitHub"),
        ("gh api -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc", "through the API"),
        ("gh api repos/O/R/git/refs -f ref=refs/heads/dev -f sha=abc", "through the API"),
        ("gh api -X DELETE repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -X POST https://api.github.com/repos/o/r/git/refs -d '{}'", "through the API"),
        ("curl -X PATCH https://api.github.com:443/repos/o/r/git/refs/heads/dev -d '{}'", "through the API"),
        ("curl -X PATCH https://API.GITHUB.COM/repos/o/r/git/refs/heads/dev -d '{}'", "through the API"),
        ("gh api --hostname GitHub.com:443 -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc", "through the API"),
        ("curl -X PATCH https://api.github.com/repos/o/r/git/refs/heads/dev -d '{}' --next -X GET https://api.github.com/user",
         "through the API"),
        ("gh api repos/O/R/merges -f base=dev -f head=feature", "merges API"),
        ("curl -X POST https://api.github.com/repos/o/r/merges -d '{}'", "merges API"),
        ("bash -c 'gh api -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc'", "through the API"),
        ("GH_HOST= gh api -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc", "through the API"),
        ("curl -G --no-get -d '{}' https://api.github.com/repos/o/r/git/refs", "through the API"),
        ("curl -G -X POST -d '{}' https://api.github.com/repos/o/r/git/refs", "through the API"),
        # curl is a read only when proven: no data option and no non-GET -X anywhere.
        ("curl -G -d per_page=1 https://api.github.com/repos/o/r/git/refs", "through the API"),
        ("curl --get --data-urlencode sha=x https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -X PATCH -X GET https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -sXPATCH https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl --request=DELETE https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -T body.json https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        # Scheme-less, protocol-relative, port and user-info URLs name the same endpoints.
        ("curl -d '{}' api.github.com/repos/o/r/merges", "merges API"),
        ("curl -X PATCH //api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -X PATCH api.github.com:443/repos/O/R/git/refs/heads/dev", "through the API"),
        ("curl -X PATCH https://x@API.github.com:443/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -X DELETE --url api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        # Option values are never flags, and unknown options never prove a read.
        ("curl -X DELETE --user-agent --next https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl -A --next -X DELETE https://api.github.com/repos/o/r/git/refs/heads/dev", "through the API"),
        ("curl --expand-request DELETE https://api.github.com/repos/o/r/git/refs/heads/main", "option the guard does not know"),
        ("""curl --expand-json '{"base":"main","head":"topic"}' https://api.github.com/repos/o/r/merges""", "option the guard does not know"),
        ("curl -K request.conf https://api.github.com/repos/o/r/git/refs/heads/dev", "option the guard does not know"),
        ("curl --req DELETE https://api.github.com/repos/o/r/git/refs/heads/dev", "option the guard does not know"),
        ("curl -s% https://api.github.com/repos/o/r/git/refs", "option the guard does not know"),
        # An unknown option anywhere makes later transfer boundaries untrustworthy.
        ("curl --frob -X DELETE --next https://api.github.com/repos/o/r/git/refs/heads/dev", "option the guard does not know"),
        ("curl https://example.org --next --frob x https://api.github.com/repos/o/r/git/refs", "option the guard does not know"),
    ):
        _, message = expect(command, 2, repo)
        assert hint in message and "git push <remote>" in message, (command, message)
    for command in ("gh api repos/o/r/git/refs/heads/dev", "gh api -X PATCH repos/o/other/git/refs/heads/dev -f sha=abc",
                    "curl -X POST https://git.example/api/v1/repos/o/r/git/refs -d '{}'",
                    "gh api repos/o/other/merges -f base=dev -f head=feature", "gh api repos/o/r/merges -X GET",
                    "gh api --hostname ghe.example -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc",
                    "GH_HOST=ghe.example gh api -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc",
                    "curl -s https://api.github.com/repos/o/r/git/refs",
                    "curl -X GET --url-query per_page=1 https://api.github.com/repos/o/r/git/refs",
                    "curl -sI https://api.github.com/repos/o/r/merges",
                    # Reading a PR's merge status is not a merge.
                    "gh api repos/o/r/pulls/7/merge", "gh api -X GET repos/O/R/pulls/9/merge",
                    "git config set --file f alias.co checkout", "git config get --file f hook.agent-pr-review.enabled",
                    "CLAUDECODE=1 git status", "unset CLAUDECODE",
                    "git config --get include.path", "git -c include.path=/tmp/x.inc status",
                    "env -i PATH=/usr/bin make", 'bash <<EOF\necho "$USER"\ngit push origin feature\nEOF',
                    "eval \"$(ssh-agent -s)\" && git push origin feature",
                    "curl -X HEAD https://api.github.com/repos/o/r/git/refs",
                    "curl -sSfL -H 'Accept: application/json' https://api.github.com/repos/o/r/git/refs",
                    "curl -X DELETE https://example.org/x --next https://api.github.com/repos/o/r/git/refs",
                    "curl --user-agent ua --max-time 5 https://api.github.com/repos/o/r/git/refs",
                    "nice env -C /tmp git push origin feature", "env -0v git push origin feature",
                    "env LANG=C git push origin feature", "curl --frob https://example.org/x",
                    "curl -X PATCH -d '{}' git.example/api/v1/repos/o/r/git/refs",
                    "curl -X PATCH -d '{}' //git.example/api/v1/repos/o/r/git/refs",
                    "curl -s api.github.com/repos/o/r/git/refs",
                    "env -- LANG=C git push origin feature"):
        assert not expect(command, 0, repo)[0], command
    # Earlier GH_HOST assignments apply to later gh api calls.
    with patch.dict(os.environ, {"GH_HOST": "ghe.example"}):
        for command in ("export GH_HOST=github.com; gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc",
                        "GH_HOST=github.com; gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc",
                        "unset GH_HOST; gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc"):
            _, message = expect(command, 2, repo)
            assert "through the API" in message, (command, message)
        assert not expect("gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc", 0, repo)[0]
    # Unlisted GitHub repositories keep the review check alone, and without a
    # listed GitHub repository nothing about pushes is refused.
    configure(f"{forgejo_host}/O/r", "github.com/o/other")
    expect("gh pr merge 7 --squash", 0, repo)
    expect("gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash", 0, repo)
    expect("gh api -X PATCH repos/o/r/git/refs/heads/dev -f sha=abc", 0, repo)
    configure(f"{forgejo_host}/O/r")
    for command in ("git push --no-verify origin +feature:dev", "GIT_CONFIG_COUNT=0 git push"):
        assert not expect(command, 0, repo)[0], command
    del os.environ["PR_REVIEW_CONFIG"]
review.run = fake_run
assert review.github_repository("ssh://git@ssh.github.com:443/O/R.git") == "O/R"
assert review.github_repository("github.com:o/r") == "o/r"
assert review.github_repository("git@github.com:/O/R.git") == "O/R"
assert review.github_repository("https://x-access-token@github.com/o/r/") == "o/r"
assert review.github_repository(f"https://{forgejo_host}/o/r") is None

# Unresolvable merge targets block with guidance.
code, message = hook("curl -X POST https://git.example/api/v1/repos/o/r/pulls/$PR/merge")
assert code == 2 and "unquoted REST arguments" in message, message


def failing_run(argv, cwd=None, stdin=None, timeout=None):
    raise review.ReviewError("gh pr view failed: offline")


def crashing_run(argv, cwd=None, stdin=None, timeout=None):
    raise TimeoutError("read timed out")


review.run = failing_run
code, message = hook("gh pr merge 5")
assert code == 2 and "could not verify" in message, message
review.run = crashing_run
code, message = hook("gh pr merge 5")
assert code == 2 and "read timed out" in message, message


def slow_run(argv, cwd=None, stdin=None, timeout=None):
    time.sleep(5)


review.GUARD_DEADLINE = 1
review.run = slow_run
code, message = hook("gh pr merge 5")
assert code == 2 and "longer than 1 seconds" in message, message
review.GUARD_DEADLINE = 90

# GH_HOST would send a gh api merge to another host than the one checked.
code, message = hook("GH_HOST=ghe.example gh api -X PUT repos/o/r/pulls/7/merge")
assert code == 2 and "only github.com" in message, message
review.run = fake_run
for command in (
    "GH_HOST=ghe.example gh pr merge 7 --repo o/r",
    "GH_REPO=other/repo gh pr merge 7",
    "gh pr merge 7 --repo ghe.example/o/r",
    "gh api --hostname=ghe.example -X PUT repos/o/r/pulls/7/merge",
    "gh api --hostname ghe.example -X PUT repos/o/r/pulls/7/merge",
    "gh api -X PUT https://ghe.example/api/v3/repos/o/r/pulls/7/merge",
):
    code, message = hook(command)
    assert code == 2 and ("only github.com" in message or "GH_HOST or GH_REPO" in message), (command, message)
assert review.review_problem(
    [f"Automated read-only review ({HEAD[:12]} on release 2026): no findings."], HEAD, "release 2026"
) is None
os.environ["GH_HOST"] = "ghe.example"
code, message = hook("gh api -X PUT repos/o/r/pulls/7/merge")
assert code == 2 and "only github.com" in message, message
del os.environ["GH_HOST"]


def late_alarm(command, cwd):
    raise TimeoutError("deadline fired late")


real_guard_check = review.guard_check
review.guard_check = late_alarm
code, message = hook("gh pr merge 5")
assert code == 2 and "deadline fired late" in message, message
review.guard_check = real_guard_check
review.run = fake_run

# Non-shell payloads are ignored.
sys.stdin = io.StringIO(json.dumps({"tool_input": {"file_path": "x"}}))
assert review.main(["guard"]) == 0
sys.stdin = io.StringIO("not json")
assert review.main(["guard"]) == 0
sys.stdin = sys.__stdin__

# Review comments must name a prefix of the head commit and the target branch.
assert review.review_problem([PINNED], HEAD, "dev") is None
assert review.review_problem([f"Automated read-only review ({HEAD[:7]} on dev): skipped (docs)."], HEAD, "dev") is None
assert "current head" in review.review_problem([STALE, "Automated read-only review: no findings."], HEAD, "dev")
assert "on main" in review.review_problem([PINNED], HEAD, "main")
assert review.review_problem(["LGTM"], HEAD, "dev") == "has no automated review comment"
assert review.review_problem([f"Automated read-only review ({HEAD[:12]} on topic(x)): no findings."], HEAD, "topic(x)") is None

# The mode follows the pinned prefix, so guards that predate it read the same target.
follow = f"Automated read-only review ({HEAD[:12]} on dev): follow-up to {'1' * 12}: fixed."
assert review.review_problem([follow], HEAD, "dev") is None and review.PINNED.match(follow)[2] == "dev"

# Changed lines count hunk lines only, including blank ones and ones that look like headers.
sample = ("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n context\n\n--- sql comment\n"
          "+++ added\n-old\n+new\ndiff --git a/y b/y\nBinary files a/y and b/y differ\n")
assert review.changed_lines(sample) == 4, review.changed_lines(sample)

assert review.token_usage({"input_tokens": 10, "cached_input_tokens": 5, "output_tokens": 0}, "codex") == {
    "input_tokens": 10, "cached_input_tokens": 5, "cache_write_input_tokens": None,
    "output_tokens": 0, "reasoning_output_tokens": None}
assert review.token_usage({"input_tokens": 10, "cache_read_input_tokens": 5,
                           "cache_creation_input_tokens": 3}, "claude")["cached_input_tokens"] == 5
for bad in (None, -1, True, "10", 1.5):
    assert review.token_usage({"input_tokens": bad}, "codex")["input_tokens"] is None
with tempfile.TemporaryDirectory() as tmp:
    events = pathlib.Path(tmp, "events.jsonl")
    events.write_text(json.dumps({"type": "item.completed", "usage": {"input_tokens": 999}}) + "\n" +
                      json.dumps({"type": "turn.completed", "usage": {"input_tokens": 12, "output_tokens": 3}}) +
                      '\n{"incomplete":')
    assert review.reviewer_usage("codex", events)["input_tokens"] == 12
    events.write_text('{"type":"turn.failed"}\n')
    assert all(value is None for value in review.reviewer_usage("codex", events).values())
    events.write_text('{"result":"Verdict: no findings", "usage":{"cache_creation_input_tokens":4}}')
    assert review.reviewer_usage("claude", events)["cache_write_input_tokens"] == 4
    events.write_text('{"broken":')
    assert all(value is None for value in review.reviewer_usage("claude", events).values())

# Fixes must not raise their own allowance by growing the current PR diff.
previous = {"head": HEAD, "merge_base": "base", "changed_lines": 100}
def additions(count):
    return "diff --git a/x b/x\n@@ -0,0 +1,100 @@\n" + "+line\n" * count

assert review.follow_up_problem(previous, "base", additions(40)) is None
assert "more than 40 lines" in review.follow_up_problem(previous, "base", additions(41))
assert review.follow_up_problem({**previous, "changed_lines": 200}, "base", additions(80)) is None
for count in (None, -1, True, "100"):
    assert "no valid changed-line count" in review.follow_up_problem(
        {**previous, "changed_lines": count}, "base", additions(1))

# Exercise cmd_run in fresh processes, with the SIGHUP dispositions inherited
# across exec just as they are under nohup. Default HUP still cancels a run.
with tempfile.TemporaryDirectory() as tmp:
    script = '''
import importlib.util, os, pathlib, signal, sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("review", sys.argv[1])
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
directory = sys.argv[2]
review.load_config = lambda: {"reviewers": []}
review.resolve = lambda *args: ("pr", "origin")
review.pr_info = lambda pr: {"head": "a" * 40, "base": "dev"}
review.state_dir = lambda *args: directory
def checkout(*args):
    os.kill(os.getpid(), signal.SIGHUP)
    pathlib.Path(directory, "survived").touch()
    raise review.ReviewError("test stopped after SIGHUP")
review.checkout = checkout
args = SimpleNamespace(pr="1", cwd=directory, remote=None, force=False, full=True, role=None)
try:
    review.cmd_run(args)
except review.ReviewError:
    pass
'''
    for ignored in (False, True):
        # This launcher sets the disposition before exec, rather than depending
        # on this test process's handlers or a subprocess preexec callback.
        launcher = '''
import os, signal, sys
signal.signal(signal.SIGHUP, signal.SIG_IGN if sys.argv[1] == "ignore" else signal.SIG_DFL)
os.execv(sys.executable, [sys.executable, "-c", *sys.argv[2:]])
'''
        result = subprocess.run([sys.executable, "-c", launcher, "ignore" if ignored else "default",
                                 script, str(ROOT / "modules/home-manager/programs/ai/pr-review.py"), tmp],
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == (0 if ignored else 129), result.stderr
        assert pathlib.Path(tmp, "survived").exists() == ignored


# Forge values used in paths and refspecs must look like a commit and a branch.
def bad_forgejo(pr, path, data=None, accept="application/json"):
    return {"head": {"sha": "/tmp/victim"}, "base": {"ref": "dev"}}


review.forgejo_request = bad_forgejo
try:
    review.pr_info(review.PR("forgejo", review.FORGEJO_URL, "o", "r", "1"))
except review.ReviewError as error:
    assert "unexpected head" in str(error), error
else:
    raise AssertionError("a non-SHA head must be refused")
review.forgejo_request = fake_forgejo
assert not review.valid_branch("x:refs/heads/main") and not review.valid_branch("../x")
assert review.valid_branch("release/1.2") and review.valid_branch("release@2026") and review.valid_branch("développement")

# Reviewers do not inherit forge credentials but keep their own.
names = ["FORGEJO_TOKEN", "GITEA_TOKEN", "GH_HOST", "MY_TOKEN_FILE", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "PATH"]
env = review.reviewer_env({name: "synthetic" for name in names})
assert set(env) == {"CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "PATH"}, env.keys()

# Codex reviewers get a home with links to the credentials and the Nix profile
# only, and PATH entries resolved out of the user's home; Claude keeps its own.
with tempfile.TemporaryDirectory() as tmp:
    tmp = os.path.realpath(tmp)
    user, codex_home, store = pathlib.Path(tmp, "user"), pathlib.Path(tmp, "codex"), pathlib.Path(tmp, "store")
    for directory in (user, codex_home, store / "bin"):
        directory.mkdir(parents=True)
    pathlib.Path(codex_home, "auth.json").write_text("synthetic\n")
    pathlib.Path(codex_home, "AGENTS.md").write_text("planted\n")
    os.symlink(store, user / ".nix-profile")
    home = os.path.join(tmp, "home")
    review.reviewer_home(home, {"HOME": str(user), "CODEX_HOME": str(codex_home)})
    assert sorted(os.listdir(home)) == [".codex", ".nix-profile"] and os.listdir(os.path.join(home, ".codex")) == ["auth.json"]
    assert os.readlink(os.path.join(home, ".codex", "auth.json")) == str(codex_home / "auth.json")
    assert os.readlink(os.path.join(home, ".nix-profile")) == str(user / ".nix-profile")
    bare = os.path.join(tmp, "bare")
    review.reviewer_home(bare, {"HOME": str(tmp)})
    assert os.listdir(bare) == [".codex"] and not os.listdir(os.path.join(bare, ".codex"))
    parent = {"PATH": os.pathsep.join([str(user / ".nix-profile/bin"), "relative", "", str(store / "bin")]), "X": "1"}
    env = review.client_env({"client": "codex"}, parent, home)
    assert env == {"PATH": str(store / "bin"), "X": "1", "HOME": home, "CODEX_HOME": os.path.join(home, ".codex")}, env
    assert review.client_env({"client": "claude"}, parent, home) is parent
    for unusable in ({}, {"PATH": ""}, {"PATH": "relative:."}):
        resolved = review.client_env({"client": "codex"}, unusable, home)["PATH"].split(os.pathsep)
        assert resolved and all(os.path.isabs(entry) for entry in resolved), resolved

    # Checkouts of killed runs are removed; those of live runs and other files are kept.
    work = pathlib.Path(tmp, "work")
    finished = subprocess.Popen(["true"])
    finished.wait()
    for name in (f"pr-review-{finished.pid}-abc", f"pr-review-{os.getpid()}-def", "other"):
        pathlib.Path(work, name, "checkout").mkdir(parents=True)
    os.symlink(codex_home / "auth.json", work / f"pr-review-{finished.pid}-abc" / "auth.json")
    review.remove_stale_work(str(work))
    assert sorted(os.listdir(work)) == sorted([f"pr-review-{os.getpid()}-def", "other"]), os.listdir(work)
    assert pathlib.Path(codex_home, "auth.json").read_text() == "synthetic\n"

# Only an opening verdict counts, not a quoted or fenced example.
with tempfile.TemporaryDirectory() as tmp:
    reply = pathlib.Path(tmp, "reply.md")
    for text, expected in (
        ("Verdict: no findings\n", True),
        ("Reading the diff.\n\n**Verdict: non-blocking findings**\n", True),
        ("Review unavailable.\n```\nVerdict: no findings\n```\n", False),
        ("I could not read the checkout. The format was:\n  `Verdict: no findings`.\n", False),
        ("a\nb\nc\nVerdict: no findings\n", False),
        ("**Verdict:** no findings\n", True),
        ("Verdict: `blocking findings`\n", True),
        ("Verdict: unable to review\n", False),
        ("Unable to review; expected format:\n> Verdict: no findings\n", False),
        ("Unable to review.\n~~~\nVerdict: no findings\n~~~\n", False),
    ):
        reply.write_text(text)
        assert review.has_verdict(str(reply)) is expected, text
    reply.write_text("**Verdict:** Non-blocking findings\n")
    assert review.reply_verdict(str(reply)) == "non-blocking findings"
    assert review.reply_verdict(None) is None

    # A round's verdict is its worst reviewer's, and none without every reviewer's.
    replies = {}
    for verdict in review.VERDICTS:
        replies[verdict] = pathlib.Path(tmp, verdict.replace(" ", "-") + ".md")
        replies[verdict].write_text(f"Verdict: {verdict}\n")
    ok = lambda verdict: {"status": "ok", "output": str(replies[verdict])}
    assert review.round_verdict({"a": ok("no findings"), "b": ok("blocking findings")}) == "blocking findings"
    assert review.round_verdict({"a": ok("no findings"), "b": ok("non-blocking findings")}) == "non-blocking findings"
    assert review.round_verdict({"a": ok("no findings"), "b": {"status": "failed", "output": str(reply)}}) is None
    assert review.round_verdict({"a": ok("no findings"), "b": {"status": "ok", "output": str(tmp)}}) is None
    assert review.round_verdict({}) is None

    # Checkpoints: consecutive blocking rounds, a long series and a large first
    # review print advice; carried rounds and other targets do not count.
    reviewer = {"name": "a", "client": "codex", "model": "m", "effort": "high"}
    checkpoint_config = {"reviewers": [reviewer]}
    pr = review.PR("forgejo", "https://forge.example", "o", "r", "9")
    with patch.dict(os.environ, {"XDG_STATE_HOME": tmp}):
        def add_round(number, verdict, base="dev", stored=True, **extra):
            sha = f"{number:040x}"
            directory = review.state_dir(pr, sha)
            os.makedirs(directory)
            status = {"head": sha, "base": base, "finished": number, "changed_lines": 10,
                      "reviewers": {"a": dict(ok(verdict), reviewer=reviewer)}, **extra}
            if stored:
                status["verdict"] = verdict
            pathlib.Path(directory, "status.json").write_text(json.dumps(status))
            return sha

        def notes(sha, base="dev"):
            return " ".join(review.checkpoint(checkpoint_config, pr, sha, base))

        first = add_round(1, "blocking findings", changed_lines=501)
        assert "changes 501 lines" in notes(first) and "Checkpoint" not in notes(first)
        assert notes(first, base="main") == "", "rounds on another target do not count"
        second = add_round(2, "blocking findings", stored=False)
        assert "the last 2 rounds had blocking findings" in notes(second) and "lines" not in notes(second)
        assert notes(first) == "", "advice waits for the head's own round to be the latest"
        add_round(3, "blocking findings", carried={"kind": "fold", "from": second})
        fourth = add_round(4, "non-blocking findings")
        assert notes(fourth) == "", "a round without blocking findings ends the streak; carries do not count"
        add_round(5, "blocking findings", base="main")
        for number in (6, 7):
            sha = add_round(number, "no findings")
        assert notes(sha) == ""
        sha = add_round(8, "non-blocking findings")
        assert "this is review round 6 of this PR" in notes(sha), notes(sha)
        sha = add_round(9, "blocking findings")
        sha = add_round(10, "blocking findings")
        assert "the last 2 rounds" in notes(sha) and "round 8" not in notes(sha), notes(sha)

    # Reviewer names become file names.
    config_path = pathlib.Path(tmp, "config.json")
    os.environ["PR_REVIEW_CONFIG"] = str(config_path)
    for name in ("prompt", "../x", ""):
        config_path.write_text(json.dumps(
            {"timeout": 1, "reviewers": [{"name": name, "client": "codex", "model": "m", "effort": "high"}]}))
        try:
            review.load_config()
        except review.ReviewError:
            pass
        else:
            raise AssertionError(f"reviewer name {name!r} must be refused")

# Remotes and URLs resolve to a forge.
assert review.parse_remote("git@github.com:o/r.git").forge == "github"
forgejo = review.parse_remote("ssh://git@git-ssh.alc.xyz:2222/o/r.git")
assert (forgejo.forge, forgejo.host, forgejo.owner, forgejo.repo) == ("forgejo", review.FORGEJO_URL, "o", "r")
assert review.parse_remote("https://github.com/o/r").repo == "r"
assert review.parse_remote("https://codeberg.org/o/r.git") is None
pr, remote = review.resolve("https://github.com/o/r/pull/12", "/", "origin")
assert (pr.forge, pr.host, str(pr), remote) == ("github", "github.com", "o/r#12", None)
try:
    review.resolve("https://attacker.example/o/r/pull/1", "/", "origin")
except review.ReviewError as error:
    assert "only github.com" in str(error), error
else:
    raise AssertionError("GitHub PR URLs must be on github.com")
pr, _ = review.resolve("https://git.example/o/r/pulls/3/files", "/", "origin")
assert (pr.forge, pr.host, pr.number) == ("forgejo", "https://git.example", "3")

# The Forgejo token is only sent to the configured Forgejo host.
sent = []


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    def open(self, request, timeout):
        sent.append((request.full_url, request.get_header("Authorization")))
        return FakeResponse(b"[]")


real_opener = review.OPENER
review.OPENER = FakeOpener()
with tempfile.TemporaryDirectory() as tmp:
    token_file = pathlib.Path(tmp, "token")
    token_file.write_text("synthetic\n")
    os.environ["FORGEJO_API_TOKEN_FILE"] = str(token_file)
    real_forgejo(review.PR("forgejo", review.FORGEJO_URL, "o", "r", "1"), "issues/1/comments")
    real_forgejo(review.PR("forgejo", "https://other.example", "o", "r", "1"), "issues/1/comments")
    assert sent[0][1] == "token synthetic" and sent[1][1] is None, sent
    try:
        real_forgejo(review.PR("forgejo", "https://other.example", "o", "r", "1"), "issues/1/comments", data={})
    except review.ReviewError:
        pass
    else:
        raise AssertionError("posting to a foreign Forgejo host must fail")
    del os.environ["FORGEJO_API_TOKEN_FILE"]
review.OPENER = real_opener
assert review.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://elsewhere.example/") is None

with tempfile.TemporaryDirectory() as tmp:
    os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
    # A bare repository stands in for the forge; insteadOf maps the GitHub remote to it.
    forge = os.path.join(tmp, "forge.git")
    repository = os.path.join(tmp, "repo")
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@example", "-C", repository]
    subprocess.run(["git", "init", "-q", "--bare", forge], check=True)
    subprocess.run(["git", "init", "-q", "-b", "dev", repository], check=True)
    subprocess.run(git + ["config", f"url.{forge}.insteadOf", "git@github.com:o/r.git"], check=True)
    subprocess.run(git + ["remote", "add", "origin", "git@github.com:o/r.git"], check=True)
    pathlib.Path(repository, "file").write_text("one\n")
    subprocess.run(git + ["add", "file"], check=True)
    subprocess.run(git + ["commit", "-qm", "init"], check=True)
    subprocess.run(git + ["push", "-q", "origin", "dev"], check=True)
    # Another clone pushes the PR head to refs/pull/4/head, so pr-review must fetch it.
    # The PR adds a line, a hook and a filtered file; neither may run during checkout.
    author = os.path.join(tmp, "author")
    subprocess.run(["git", "clone", "-q", "-b", "dev", forge, author], check=True)
    author_git = ["git", "-c", "user.name=t", "-c", "user.email=t@example", "-C", author]
    pathlib.Path(author, "file").write_text("one\n{braces} survive\n")
    hook_dir = pathlib.Path(author, "hooks")
    hook_dir.mkdir()
    pathlib.Path(hook_dir, "post-checkout").write_text(f"#!/bin/sh\ntouch {tmp}/hook-ran\n")
    os.chmod(hook_dir / "post-checkout", 0o755)
    pathlib.Path(author, ".gitattributes").write_text("file filter=probe\n")
    os.symlink("/etc/passwd", os.path.join(author, "link"))
    subprocess.run(author_git + ["add", "file", "hooks", ".gitattributes", "link"], check=True)

    def git_out(*args, stdin=None):
        return subprocess.run(author_git + list(args), input=stdin, capture_output=True, text=True, check=True).stdout.strip()

    # Git refuses to stage .git paths, so build a tree containing sub/.GIT directly.
    blob = git_out("hash-object", "-w", "--stdin", stdin="gitdir: /elsewhere\n")
    sub = git_out("mktree", stdin=f"100644 blob {blob}\t.GIT\n")
    root = git_out("ls-tree", git_out("write-tree")) + f"\n040000 tree {sub}\tsub\n"
    commit = git_out("commit-tree", git_out("mktree", stdin=root), "-p", "HEAD", "-m", "change")
    subprocess.run(author_git + ["push", "-q", "origin", f"{commit}:refs/pull/4/head"], check=True)
    head = commit
    # Hooks that fetch and update-ref would trigger, and a working-tree
    # .gitattributes that would mark the diff binary, must not take effect.
    clone_hooks = pathlib.Path(tmp, "clone-hooks")
    clone_hooks.mkdir()
    for name in ("reference-transaction", "post-checkout"):
        pathlib.Path(clone_hooks, name).write_text(f"#!/bin/sh\ntouch {tmp}/hook-ran\n")
        os.chmod(clone_hooks / name, 0o755)
    subprocess.run(git + ["config", "core.hooksPath", str(clone_hooks)], check=True)
    pathlib.Path(repository, ".gitattributes").write_text("* binary\n")
    subprocess.run(git + ["config", "filter.probe.smudge", f"touch {tmp}/filter-ran; cat"], check=True)

    # The user's home holds instructions, skills and a CLAUDE.md that reviewers
    # must not see, next to the credentials Codex needs.
    user_home = pathlib.Path(tmp, "user-home")
    for planted in (".codex/AGENTS.md", ".agents/skills/planted/SKILL.md", ".claude/CLAUDE.md"):
        pathlib.Path(user_home, planted).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(user_home, planted).write_text("Planted user-level instruction.\n")
    pathlib.Path(user_home, ".codex/auth.json").write_text("synthetic-auth\n")
    pathlib.Path(user_home, ".nix-profile/bin").mkdir(parents=True)
    os.environ["HOME"] = str(user_home)
    os.environ.pop("CODEX_HOME", None)
    os.environ.pop("CLAUDE_CONFIG_DIR", None)

    # Fake reviewer CLIs: codex writes its -o file and reports its model on
    # stderr; claude prints a JSON result with per-model usage to stdout. Each
    # fails if it would load the planted files the way the real client finds
    # them: Codex from CODEX_HOME (or ~/.codex) despite --ignore-user-config,
    # and ~/.agents/skills; Claude from its config directory unless restricted.
    bin_dir = os.path.join(tmp, "bin")
    os.mkdir(bin_dir)
    scripts = {
        "codex": 'cat >/dev/null; case "$*" in *"mcp_oauth_credentials_store=\\"file\\" -c cli_auth_credentials_store=\\"file\\" '
                 '-c default_permissions=\\"pr-review\\""*"\\":root\\"=\\"deny\\""*"\\":workspace_roots\\"=\\"read\\"}"*'
                 '"--ignore-user-config --ignore-rules --disable apps --disable plugins --disable remote_plugin --json"*) ;; *) exit 3;; esac; '
                 'case "$*" in *"-s read-only"*) exit 3;; esac; '
                 'test ! -e "${CODEX_HOME:-$HOME/.codex}/AGENTS.md" && test ! -e "$HOME/.agents" || exit 8; '
                 'test -L "$CODEX_HOME/auth.json" && test "$(cat "$CODEX_HOME/auth.json")" = synthetic-auth || exit 9; '
                 'test -d "$HOME/.nix-profile/bin" || exit 10; '
                 'test -z "$FORGEJO_API_TOKEN_FILE$GH_TOKEN" || exit 4; '
                 'printf "OpenAI Codex\\n--------\\nmodel: gpt-reported\\n--------\\nuser\\nmodel: gpt-spoofed\\n" >&2; '
                 'printf \'{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":9}}\\n\'; '
                 'while [ "$1" != -o ]; do shift; done; test -f file && echo "Verdict: no findings" >"$2"',
        "claude": 'cat >/dev/null; test -f file || exit 1; test ! -L link || exit 5; test ! -e sub/.GIT || exit 7; '
                  'case "$*" in *"--restricted --safe-mode"*) ;; *) test ! -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md" || exit 8;; esac; '
                  'test "$(cat link)" = "symbolic link to /etc/passwd" || exit 6; '
                  'case "$*" in *"--restricted"*"--output-format json"*) printf \'{"result": "Reading the diff.\\\\n\\\\n**Verdict: no findings**", '
                  '"usage":{"input_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10,"output_tokens":93}, '
                  '"modelUsage": {"claude-helper": {"outputTokens": 3}, "claude-reported": {"outputTokens": 90}}}\';; *) exit 3;; esac',
    }
    for name, body in scripts.items():
        path = os.path.join(bin_dir, name)
        pathlib.Path(path).write_text(f"#!/bin/sh\n{body}\n")
        os.chmod(path, 0o755)
    os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
    os.environ["GH_TOKEN"] = "synthetic"

    config = {
        "timeout": 20,
        "reviewers": [
            {"name": "gpt", "client": "codex", "model": "m", "effort": "high"},
            {"name": "opus", "client": "claude", "model": "m", "effort": "high"},
        ],
    }
    os.environ["PR_REVIEW_CONFIG"] = os.path.join(tmp, "config.json")
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))

    posted = []
    review.run = real_run
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}
    review.post_comment = lambda pr, body: posted.append((str(pr), body))

    def cli(*argv):
        out, err = io.StringIO(), io.StringIO()
        sys.stdout, sys.stderr = out, err
        old = os.getcwd()
        os.chdir(repository)
        try:
            return review.main(list(argv)), out.getvalue() + err.getvalue()
        finally:
            os.chdir(old)
            sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__

    # Comments other than skips need a completed review of the current head.
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "pr-review run 4" in output and not posted, output
    code, output = cli("comment", "4", "Automated read-only review: skipped (docs only).")
    assert code == 0 and posted[-1] == ("o/r#4", f"Automated read-only review ({head[:12]} on dev): skipped (docs only)."), posted

    # Both reviewers run against a detached checkout of the head commit.
    code, output = cli("run", "4")
    assert code == 0, output
    assert output.count("Verdict: no findings") == 2, output
    assert "Reading the diff." in output, output
    state = os.path.join(tmp, "state", "pr-review", "github.com", "o", "r", "4", head)
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert {r["status"] for r in status["reviewers"].values()} == {"ok"}, status
    assert status["reviewers"]["gpt"]["usage"]["cached_input_tokens"] == 40, status
    assert status["reviewers"]["opus"]["usage"]["cache_write_input_tokens"] == 10, status
    assert status["changed_lines"] == review.changed_lines(pathlib.Path(state, "prompt.md").read_text()), status
    # Roles can pass aliases (ADR-0079), so the recorded model is the reported one.
    reported = {name: r["reported_model"] for name, r in status["reviewers"].items()}
    assert reported == {"gpt": "gpt-reported", "opus": "claude-helper, claude-reported"}, reported
    assert "gpt: ok" in output and "gpt-reported)" in output and "claude-helper, claude-reported)" in output, output
    assert status["verdict"] == "no findings", status
    prompt = pathlib.Path(state, "prompt.md").read_text()
    assert "+{braces} survive" in prompt and "+one" not in prompt, prompt
    assert "Calibrate what you report:" in prompt and "as a low finding for the owner" in prompt, prompt
    assert not os.path.exists(os.path.join(tmp, "hook-ran")), "repository hooks must not run"
    assert not os.path.exists(os.path.join(tmp, "filter-ran")), "checkout filters must not run"
    refs = subprocess.run(git + ["for-each-ref", "refs/pr-review"], capture_output=True, text=True).stdout
    assert not refs, refs

    code, output = cli("run", "4")
    assert code == 0 and "already reviewed" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 0 and posted[-1][1] == f"Automated read-only review ({head[:12]} on dev): full (deep): no findings.", posted

    # JSON mode can omit Codex's header. Never copy a claimed model from its
    # agent text, or pretend the configured model was reported by the client.
    pathlib.Path(bin_dir, "codex").write_text(
        '#!/bin/sh\ncat >/dev/null\nprintf \'{"type":"turn.completed","usage":{"input_tokens":7}}\\n\'\n'
        'while [ "$1" != -o ]; do shift; done\necho "Verdict: no findings" >"$2"\n')
    code, output = cli("run", "4", "--force")
    assert code == 0, output
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert status["reviewers"]["gpt"]["reported_model"] is None, status
    assert status["reviewers"]["gpt"]["reviewer"] == config["reviewers"][0], status
    assert status["reviewers"]["gpt"]["usage"]["input_tokens"] == 7, status
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\n" + scripts["codex"] + "\n")

    # A reviewer that exits 0 without a valid verdict has not reviewed anything.
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\ncat >/dev/null\necho '{\"result\": \"Verdict: unable to review\"}'\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: failed" in output, output
    assert "Reason: replied without a verdict: Verdict: unable to review" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by opus;" in output, output
    # A malformed JSON result is a failed review, not a crash, and the other
    # reviewer's result is still recorded.
    pathlib.Path(bin_dir, "claude").write_text(
        "#!/bin/sh\ncat >/dev/null\necho '{\"result\": null, \"modelUsage\": {\"x\": {\"outputTokens\": null}}}'\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: failed" in output and "gpt: ok" in output, output
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert status["reviewers"]["gpt"]["reported_model"] == "gpt-reported", status
    assert all(value is None for value in status["reviewers"]["opus"]["usage"].values()), status
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    code, output = cli("run", "4")
    assert code == 0, output

    # Each reviewer records its own run time, not the time it waited behind
    # the reviewers checked before it.
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\nsleep 2\n" + scripts["codex"] + "\n")
    code, output = cli("run", "4", "--force")
    assert code == 0, output
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert status["reviewers"]["gpt"]["seconds"] >= 2 > status["reviewers"]["opus"]["seconds"], status

    # A usage limit is a missing review recorded as `limited`, with the reset
    # the client claims. A later plain run keeps the review the other reviewer
    # completed with the same prompt and runs only the missing one.
    codex_calls = os.path.join(tmp, "codex-calls")
    pathlib.Path(bin_dir, "codex").write_text(f"#!/bin/sh\necho run >>{codex_calls}\n" + scripts["codex"] + "\n")
    limit_reply = os.path.join(tmp, "limit.json")
    pathlib.Path(limit_reply).write_text(json.dumps({
        "type": "result", "subtype": "success", "is_error": True, "api_error_status": 429,
        "api_error": "usage_limit_reached", "result": "You've hit your weekly limit · resets Oct 23, 1pm (Europe/Oslo)",
    }))
    pathlib.Path(bin_dir, "claude").write_text(f"#!/bin/sh\ncat >/dev/null\ncat {limit_reply}\nexit 1\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: limited" in output and "gpt: ok" in output, output
    assert "Reason: usage limit: You've hit your weekly limit" in output, output
    assert "the client says Oct 23, 1pm (Europe/Oslo)" in output and "does not mean no findings" in output, output
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert status["reviewers"]["opus"]["limit"]["resets"] == "Oct 23, 1pm (Europe/Oslo)", status
    assert status["verdict"] is None, status
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by opus;" in output, output
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    code, output = cli("run", "4")
    assert code == 0 and "Keeping the completed review of this head by gpt" in output, output
    assert "gpt: ok" in output and "kept from the last run" in output, output
    assert pathlib.Path(codex_calls).read_text().count("run") == 1, "the kept reviewer must not run again"
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert status["reviewers"]["gpt"]["reused"] is True and "reused" not in status["reviewers"]["opus"], status
    assert status["verdict"] == "no findings", status
    code, output = cli("comment", "4", "no findings.")
    assert code == 0, output
    # Only the run that kept a review labels it so.
    code, output = cli("run", "4")
    assert code == 0 and "already reviewed" in output and "kept from the last run" not in output, output
    # A changed prompt, here the PR description, keeps nothing.
    pathlib.Path(bin_dir, "claude").write_text(f"#!/bin/sh\ncat >/dev/null\ncat {limit_reply}\nexit 1\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and pathlib.Path(codex_calls).read_text().count("run") == 2, output
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    review.pr_info = lambda pr: {"title": "t", "body": "edited", "head": head, "base": "dev", "url": "u"}
    code, output = cli("run", "4")
    assert code == 0 and "Keeping" not in output and pathlib.Path(codex_calls).read_text().count("run") == 3, output
    # A description with CRLF line endings still matches its saved prompt.
    review.pr_info = lambda pr: {"title": "t", "body": "one\r\ntwo", "head": head, "base": "dev", "url": "u"}
    pathlib.Path(bin_dir, "claude").write_text(f"#!/bin/sh\ncat >/dev/null\ncat {limit_reply}\nexit 1\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and pathlib.Path(codex_calls).read_text().count("run") == 4, output
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    code, output = cli("run", "4")
    assert code == 0 and "Keeping" in output and pathlib.Path(codex_calls).read_text().count("run") == 4, output
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}
    # A transient rate limit is an ordinary failure, not a usage limit.
    rate_reply = os.path.join(tmp, "rate.json")
    pathlib.Path(rate_reply).write_text(json.dumps({"type": "result", "is_error": True, "api_error_status": 429,
                                                    "result": "You've hit your rate limit, slow down"}))
    pathlib.Path(bin_dir, "claude").write_text(f"#!/bin/sh\ncat >/dev/null\ncat {rate_reply}\nexit 1\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: failed" in output and "opus: limited" not in output, output
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    # Codex reports its limit as an error event, with its own reset wording.
    pathlib.Path(bin_dir, "codex").write_text(
        "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":"
        "\"You have hit your usage limit. Upgrade to Plus to continue using Codex, or try again at 3:42 PM.\"}}'\nexit 1\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "gpt: limited" in output and "the client says 3:42 PM" in output, output
    # Limit wording quoted in the PR itself, which Codex echoes to its log, is
    # not a limit: only the client's own error reports count.
    review.pr_info = lambda pr: {"title": "t", "body": "You've hit your usage limit", "head": head, "base": "dev",
                                 "url": "u"}
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\ncat >&2\nexit 1\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "gpt: failed" in output and "gpt: limited" not in output, output
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\n" + scripts["codex"] + "\n")
    code, output = cli("run", "4", "--force")
    assert code == 0, output

    # Only one run per PR head at a time.
    import fcntl
    with open(os.path.join(state, "lock"), "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        code, output = cli("run", "4", "--force")
    assert code == 1 and "already reviewing" in output, output
    code, output = cli("run", "4")
    assert code == 0, output

    # Retargeting the PR invalidates the earlier result.
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "main", "url": "u"}
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by gpt, opus;" in output, output
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}

    # The head must not move while the PR is checked out.
    heads = iter([head, "f" * 40])
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": next(heads), "base": "dev", "url": "u"}
    code, output = cli("run", "4", "--force")
    assert code == 1 and "changed while it was checked out" in output, output
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}
    code, output = cli("comment", "4", "no findings.")
    assert code == 1, "a forced run drops the earlier result even when it stops early"
    code, output = cli("run", "4")
    assert code == 0, output

    # A changed reviewer model invalidates the earlier result.
    config["reviewers"][1]["model"] = "m2"
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by opus;" in output, output

    # Failures and timeouts are reported as missing reviews, never as no findings,
    # even when a stalled reviewer never reads a prompt larger than a pipe buffer.
    review.pr_info = lambda pr: {"title": "t", "body": "x" * 300_000, "head": head, "base": "dev", "url": "u"}
    config["timeout"] = 1
    config["reviewers"][1] = {"name": "opus", "client": "codex", "model": "m", "effort": "high"}
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\nsleep 30\n")
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    started = time.monotonic()
    code, output = cli("run", "4", "--force")
    assert time.monotonic() - started < 10, "the timeout must apply while the prompt is pending"
    assert code == 1 and "timeout" in output and "does not mean no findings" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "gpt, opus" in output, output

    # Follow-ups: small fixes on top of the last completed round review only the fixes.
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\n" + scripts["codex"] + "\n")
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    config["timeout"] = 20
    config["reviewers"][1] = {"name": "opus", "client": "claude", "model": "m", "effort": "high"}
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    rounds = os.path.dirname(state)

    def at(sha, base="dev"):
        review.pr_info = lambda pr: {"title": "t", "body": "", "head": sha, "base": base, "url": "u"}

    def push(content, *parents, ref="refs/pull/4/head", files=None, extra=""):
        """Commit `file` with `content` on top of `parents`, the other files from `files`, and push it to `ref`."""
        blob = git_out("hash-object", "-w", "--stdin", stdin=content)
        listing = [line for line in git_out("ls-tree", files or parents[0]).splitlines() if not line.endswith("\tfile")]
        tree = git_out("mktree", stdin="\n".join(listing + [f"100644 blob {blob}\tfile"]) + "\n" + extra)
        sha = git_out("commit-tree", tree, *[arg for parent in parents for arg in ("-p", parent)], "-m", "c")
        subprocess.run(author_git + ["push", "-qf", "origin", f"{sha}:{ref}"], check=True)
        return sha

    def state_of(sha):
        return json.loads(pathlib.Path(rounds, sha, "status.json").read_text())

    def review_round(sha, expected, *flags, base="dev", role="deep"):
        """Run on `sha` and return the mode its comment records, after checking its role."""
        at(sha, base)
        code, output = cli("run", "4", *flags)
        assert code == 0 and expected in output, (expected, output)
        code, output = cli("comment", "4", "no findings.")
        assert code == 0, output
        mode = posted[-1][1].split("): ", 1)[1].rsplit(": ", 1)[0]
        assert mode.endswith(f" ({role})"), posted[-1]
        return mode.removesuffix(f" ({role})")

    # A round from before follow-ups lacks a merge base, so the next one is full.
    at(head)
    code, output = cli("run", "4", "--force")
    assert code == 0 and "(full review: --force repeats the full review of this head)" in output, output
    status = state_of(head)
    for key in ("mode", "finished", "merge_base", "response"):
        status.pop(key, None)
    pathlib.Path(rounds, head, "status.json").write_text(json.dumps(status))
    first = push("one\n{braces} survive\nfirst\n", head)
    assert review_round(first, f"(full review: the round at {head[:12]} predates follow-ups)",
                        "--response", "kept the parser.") == "full"
    assert "## Author's response to earlier findings\n\nkept the parser." in \
        pathlib.Path(rounds, first, "prompt.md").read_text()

    # The follow-up gives every reviewer the previous findings, the response
    # and the interdiff, with the whole PR diff as context. No comment is needed
    # on the earlier round.
    fix = push("one\n{braces} survive\nfixed\n", first)
    assert review_round(fix, f"(follow-up to {first[:12]})", "--response", "fixed the parser.") \
        == f"follow-up to {first[:12]}"
    status = state_of(fix)
    assert (status["mode"], status["previous"], status["root"], status["followups"]) == ("follow-up", first, first, 1)
    prompt = pathlib.Path(rounds, fix, "prompt.md").read_text()
    assert "This is a follow-up review" in prompt and "## Author's response\n\nfixed the parser." in prompt, prompt
    assert "Calibrate what you report:" in prompt, prompt
    assert f"### Round at {first[:12]} (full)" in prompt and "#### gpt\n\nVerdict: no findings" in prompt, prompt
    interdiff, whole = prompt.split("## Interdiff")[1].split("## Full PR diff")
    assert "+fixed" in interdiff and "+{braces}" not in interdiff and "+{braces} survive" in whole, prompt
    assert os.path.exists(pathlib.Path(rounds, head, "status.json")), "earlier rounds are kept"

    # --force on a follow-up repeats the follow-up.
    code, output = cli("run", "4", "--force", "--response", "fixed the parser.")
    assert code == 0 and f"(follow-up to {first[:12]})" in output and "Hint:" not in output, output

    # Later follow-ups see every round since the full review; at most
    # MAX_FOLLOW_UPS run in a row.
    for count in (2, 3):
        fix = push(f"one\n{{braces}} survive\nfixed {count}\n", fix)
        assert review_round(fix, "(follow-up to").startswith("follow-up to")
        assert (state_of(fix)["followups"], state_of(fix)["root"]) == (count, first)
    prompt = pathlib.Path(rounds, fix, "prompt.md").read_text()
    assert prompt.count("### Round at") == 3 and "Author's response before this round:\n\nfixed the parser." in prompt
    # Past the limit, a head that rewrites the reviewed one still gets the fold hint.
    fix = push("one\n{braces} survive\nfixed 4\n", first)
    at(fix)
    code, output = cli("run", "4")
    assert code == 0 and "(full review: 3 follow-ups in a row)" in output, output
    assert "Hint: this head does not build on the reviewed" in output, output

    # --full reviews the whole PR, also again after a follow-up of the same head.
    fix = push("one\n{braces} survive\nfixed 5\n", fix)
    at(fix)
    code, output = cli("run", "4")
    assert code == 0 and state_of(fix)["mode"] == "follow-up", output
    assert review_round(fix, "(full review: --full was given)", "--full") == "full"

    # --force on a follow-up repeats it against its own round, not the latest one.
    full_round, fix = fix, push("one\n{braces} survive\nfixed 6\n", fix)
    assert review_round(fix, f"(follow-up to {full_round[:12]})") == f"follow-up to {full_round[:12]}"
    at(push("unrelated\n", fix))
    assert cli("run", "4")[0] == 0
    at(fix)
    code, output = cli("run", "4", "--force")
    assert code == 0 and f"(follow-up to {full_round[:12]})" in output, output

    # The prompt bound covers the follow-up's interdiff and earlier findings: a
    # follow-up that would exceed it is a full review, and a full prompt that
    # exceeds it is refused.
    full_size = len(pathlib.Path(rounds, full_round, "prompt.md").read_bytes())
    follow_size = len(pathlib.Path(rounds, fix, "prompt.md").read_bytes())
    assert follow_size > full_size + 200, (follow_size, full_size)
    with patch.object(review, "MAX_PROMPT_BYTES", full_size + 200):
        bounded = push("one\n{braces} survive\nfixed 7\n", fix)
        assert review_round(bounded, "(full review: a follow-up prompt would exceed") == "full"
    with patch.object(review, "MAX_PROMPT_BYTES", full_size - 200):
        at(push("one\n{braces} survive\nfixed 8\n", bounded))
        code, output = cli("run", "4")
        assert code != 0 and "review prompt exceeds" in output, output
    # Make `fix` the latest round again for the checks below.
    at(fix)
    code, output = cli("run", "4", "--force")
    assert code == 0 and f"(follow-up to {full_round[:12]})" in output, output

    # A large or binary change, a rebase, merging the target in, a retarget
    # or changed reviewers each need a full review.
    fix = push("one\n{braces} survive\n" + "more\n" * 60, fix)
    review_round(fix, "(full review: more than 40 lines changed since")
    binary = git_out("hash-object", "-w", "--stdin", stdin="\0binary\n")
    fix = push("one\n", fix, extra=f"100644 blob {binary}\tblob.bin\n")
    review_round(fix, "(full review: binary files changed since")
    dev = git_out("rev-parse", "origin/dev")
    fix = push("rebased\n", dev, files=fix)
    at(fix)
    code, output = cli("run", "4")
    assert code == 0 and "(full review: the head does not descend from" in output, output
    assert "Hint: this head does not build on the reviewed" in output, output
    moved = push("dev moved\n", dev, ref="refs/heads/dev")
    fix = push("rebased\nmerged\n", fix, moved)
    review_round(fix, "(full review: the merge base with the target changed since")
    push("main\n", dev, ref="refs/heads/main")
    fix = push("rebased\nmerged\nretargeted\n", fix)
    review_round(fix, "(full review: no earlier completed round on main", base="main")
    # Removing a reviewer would drop its findings from the follow-up.
    removed = config["reviewers"].pop()
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    fix = push("rebased\nmerged\nretargeted\nreviewers\n", fix)
    review_round(fix, "(full review: no earlier completed round on main with the current reviewers", base="main")
    # A cached follow-up by other reviewers no longer counts.
    fix = push("rebased\nmerged\nretargeted\nreviewers\nagain\n", fix)
    review_round(fix, f"(follow-up to", base="main")
    config["reviewers"].append(removed)
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by gpt, opus;" in output, output

    # A missing earlier round falls back to a full review.
    config["reviewers"].pop()
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    os.remove(pathlib.Path(rounds, state_of(fix)["previous"], "gpt.md"))
    fix = push("rebased\nmerged\nretargeted\nreviewers\nagain\nmissing\n", fix)
    review_round(fix, "(full review: an earlier round's findings are missing since", base="main")
    # So does an earlier round that is no longer complete, deeper in the chain.
    root = fix
    fix = push("chain 1\n", root)
    review_round(fix, f"(follow-up to {root[:12]})", base="main")
    fix = push("chain 2\n", fix)
    review_round(fix, "(follow-up to", base="main")
    status = state_of(root)
    status["reviewers"]["gpt"]["status"] = "failed"
    pathlib.Path(rounds, root, "status.json").write_text(json.dumps(status))
    fix = push("chain 3\n", fix)
    review_round(fix, "(full review: an earlier round's findings are missing since", base="main")

    # A growing fix would pass against the new diff's 40% allowance, but
    # must be measured against the diff the previous reviewers actually saw.
    content = "reviewed\n" * 100
    fix = push(content, fix)
    review_round(fix, "(full review:", "--full", base="main")
    prior_lines = state_of(fix)["changed_lines"]
    assert 100 <= prior_lines < 110, prior_lines
    fix = push(content + "fix\n" * 50, fix)
    limit = max(review.FOLLOW_UP_LINES, int(review.FOLLOW_UP_SHARE * prior_lines))
    review_round(fix, f"(full review: more than {limit} lines changed since", base="main")
    assert state_of(fix)["changed_lines"] == prior_lines + 50
    # Old state is still usable for exact-head comments, but cannot supply a
    # follow-up allowance. Do not reconstruct it from today's target branch.
    status = state_of(fix)
    status.pop("changed_lines")
    pathlib.Path(rounds, fix, "status.json").write_text(json.dumps(status))
    at(fix, "main")
    assert cli("comment", "4", "no findings.")[0] == 0
    fix = push(content + "fix\n" * 51, fix)
    review_round(fix, "has no valid changed-line count)", base="main")

    # A removed reviewer's obsolete failure never appears in cached output or
    # determines the exit status. A different reviewer set gets a fresh round.
    status = state_of(fix)
    status["reviewers"]["obsolete"] = {"status": "failed"}
    pathlib.Path(rounds, fix, "status.json").write_text(json.dumps(status))
    at(fix, "main")
    code, output = cli("run", "4")
    assert code == 0 and "obsolete:" not in output, output
    assert set(state_of(fix)["reviewers"]) == {"gpt"}

    # Keep the accepted latest-completed-round rule after an abandoned push:
    # an older ancestor is deliberately not selected to save a full review.
    abandoned = push(content + "abandoned\n", fix)
    review_round(abandoned, "(full review:", "--full", base="main")
    returned = push(content + "returned\n", fix)
    review_round(returned, "(full review: the head does not descend from", base="main")

    # Roles: small documentation-only changes get the light reviewers; agent
    # rules, decisions, security-adjacent paths, code and large diffs get deep.
    def diff_of(*paths, lines=1):
        return "".join(f"diff --git a/{path} b/{path}\n@@ -1 +1 @@\n" + "+x\n" * lines for path in paths)

    roles = dict(config, light_reviewers=[{"name": "gpt-light", "client": "codex", "model": "l", "effort": "medium"}])
    assert review.choose_role(config, diff_of("README.md"))[0] == "deep", "without light reviewers"
    assert review.choose_role(roles, diff_of("README.md", "docs/guide.mdx"))[0] == "light"
    for path in ("AGENTS.md", "docs/adr/0001-x.md", "docs/secrets.md", "docs/repo-hosting-policy.md", "file", "a.py",
                 "requirements.txt", ".claude/agents/reviewer.md", "skills/x/SKILL.md", ".github/copilot-instructions.md"):
        assert review.choose_role(roles, diff_of("README.md", path))[0] == "deep", path
    assert review.choose_role(roles, diff_of("README.md", lines=301))[0] == "deep"
    assert review.choose_role(roles, 'diff --git "a/x y.md" "b/x y.md"\n')[0] == "deep", "unreadable paths"
    assert review.choose_role(roles, "")[0] == "deep"
    # Paths containing " b/" make the header ambiguous; renames are checked by their own lines.
    assert review.choose_role(roles, "diff --git a/AGENTS.md b/archive.md b/README.md b/README.md\n")[0] == "deep"
    renamed = "diff --git a/old.md b/new.md\nsimilarity index 100%\nrename from AGENTS.md\nrename to new.md\n"
    assert review.choose_role(roles, renamed)[0] == "deep"

    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(roles))
    # The fake reviewers need `file`, so a docs-only PR changes only guide.md on a base that has it.
    base = push("base\n", dev, ref="refs/heads/docs-base")
    at(base, "docs-base")
    guide = git_out("hash-object", "-w", "--stdin", stdin="guide\n")
    light = push("base\n", base, extra=f"100644 blob {guide}\tguide.md\n")
    assert review_round(light, "with the light reviewers gpt-light (documentation only", base="docs-base",
                        role="light") == "full"
    assert set(state_of(light)["reviewers"]) == {"gpt-light"}, state_of(light)
    # A follow-up with the same role builds on the light round.
    guide2 = git_out("hash-object", "-w", "--stdin", stdin="guide fixed\n")
    fixed = push("base\n", light, extra=f"100644 blob {guide2}\tguide.md\n")
    assert review_round(fixed, f"(follow-up to {light[:12]})", base="docs-base", role="light") \
        == f"follow-up to {light[:12]}"
    # A change of role since the last round needs a full review.
    code_change = push("base\nmore\n", fixed, extra=f"100644 blob {guide2}\tguide.md\n")
    review_round(code_change, f"(full review: the round at {fixed[:12]} had light reviewers)", base="docs-base")
    # --role deep reviews a documentation-only change with the deep reviewers.
    guide3 = git_out("hash-object", "-w", "--stdin", stdin="other guide\n")
    other = push("base\n", base, extra=f"100644 blob {guide3}\tguide.md\n")
    assert review_round(other, "with the deep reviewers gpt (--role was given)", "--role", "deep",
                        base="docs-base") == "full"
    # --role can only raise the role.
    try:
        cli("run", "4", "--role", "light")
    except SystemExit as error:
        assert error.code == 2
    else:
        raise AssertionError("--role light must be refused")

    # Carries: a pure rebase of the last completed round's commits gets that
    # round's reviews without running reviewers, and its own comment mode.
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    other_blob = git_out("hash-object", "-w", "--stdin", stdin="target moved\n")
    target = push("carry base\n", dev, ref="refs/heads/carry")
    reviewed = push("carry base\nreviewed\n", target)
    review_round(reviewed, "(full review:", "--full", base="carry")
    moved = push("carry base\n", target, ref="refs/heads/carry", extra=f"100644 blob {other_blob}\tother\n")
    rebased = push("carry base\nreviewed\n", moved)
    at(rebased, "carry")
    reviewers_ran = os.path.getmtime(pathlib.Path(rounds, reviewed, "gpt.md"))
    code, output = cli("run", "4")
    assert code == 0 and f"Carried the deep review of o/r#4 by gpt from {reviewed[:12]} to {rebased[:12]} (rebase)" \
        in output, output
    assert "Reviewing" not in output, output
    # The carried findings are shown before the outcome is posted.
    assert "===== gpt: ok" in output and "Verdict: no findings" in output, output
    status = state_of(rebased)
    assert status["carried"] == {"kind": "rebase", "from": reviewed, "from_merge_base": target}, status
    assert (status["mode"], status["merge_base"], status["changed_lines"]) == (
        "full", moved, state_of(reviewed)["changed_lines"]), status
    assert pathlib.Path(rounds, rebased, "gpt.md").read_text() == pathlib.Path(rounds, reviewed, "gpt.md").read_text()
    assert all(value is None for value in status["reviewers"]["gpt"]["usage"].values()), status
    assert os.path.getmtime(pathlib.Path(rounds, reviewed, "gpt.md")) == reviewers_ran
    code, output = cli("comment", "4", f"carried from {reviewed[:12]} (rebase) (deep): no findings.")
    body = f"Automated read-only review ({rebased[:12]} on carry): carried from {reviewed[:12]} (rebase) (deep): no findings."
    assert code == 0 and posted[-1][1] == body, posted[-1]
    # The guard and older parsers read the head and target from the pinned prefix.
    assert review.review_problem([body], rebased, "carry") is None and review.PINNED.match(body)[2] == "carry"
    assert "current head" in review.review_problem([body], reviewed, "carry")
    code, output = cli("run", "4")
    assert code == 0 and "already reviewed" in output, output
    # A follow-up builds on the carried round, with its source's findings.
    fix = push("carry base\nreviewed\nfixed\n", rebased)
    at(fix, "carry")
    code, output = cli("run", "4")
    assert code == 0 and f"No carry from {rebased[:12]}: the head adds commits to it." in output, output
    assert f"(follow-up to {rebased[:12]})" in output, output
    prompt = pathlib.Path(rounds, fix, "prompt.md").read_text()
    assert f"### Round at {rebased[:12]} (full, carried from {reviewed[:12]})" in prompt, prompt
    # --full and --force review a carried head, and --full never carries.
    at(rebased, "carry")
    code, output = cli("run", "4", "--full")
    assert code == 0 and "(full review: --full was given)" in output and "Carried" not in output, output
    assert "carried" not in state_of(rebased)
    moved = push("carry base\n", moved, ref="refs/heads/carry", extra=f"100644 blob {other_blob}\tmore\n")
    again = push("carry base\nreviewed\n", moved)
    assert review_round(again, "(full review: --full was given)", "--full", base="carry") == "full"
    # A git call that times out during the carry falls back to a review.
    real_subprocess_run = subprocess.run

    def slow_cat_file(argv, *args, **kwargs):
        if "cat-file" in argv and "commit" in argv:
            raise subprocess.TimeoutExpired(argv, 120)
        return real_subprocess_run(argv, *args, **kwargs)

    moved = push("carry base\n", moved, ref="refs/heads/carry", extra=f"100644 blob {other_blob}\tlate\n")
    late = push("carry base\nreviewed\n", moved)
    at(late, "carry")
    with patch.object(review.subprocess, "run", slow_cat_file):
        code, output = cli("run", "4")
    assert code == 0 and f"No carry from {again[:12]}: reading commit" in output and "timed out" in output, output
    assert "(full review:" in output and "carried" not in state_of(late), output
    # A carry needs a completed round on the same target.
    push("carry base\n", moved, ref="refs/heads/carry-other", files=moved)
    elsewhere = push("carry base\nreviewed\n", moved)
    review_round(elsewhere, "(full review: no earlier completed round on carry-other", base="carry-other")
    assert "carried" not in state_of(elsewhere)

# Carry rules, on repositories rebased and folded by git itself.
FIXTURE_ENV = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                   GIT_SEQUENCE_EDITOR="true", GIT_EDITOR="true")
OPERATOR, AGENT = "operator@example.invalid", "agent@example.invalid"
LINES = "".join(f"line {number}\n" for number in range(1, 21))


class Fixture:
    """A repository whose `topic` branch was reviewed at `reviewed` on the merge base `base`."""

    def __init__(self, path, content=LINES, object_format="sha1"):
        self.path = path
        os.makedirs(path)
        self.git("init", "-q", "-b", "dev", f"--object-format={object_format}")
        self.write(content)
        self.base = self.commit("base")
        self.git("checkout", "-qb", "topic")

    def git(self, *args, email=OPERATOR, check=True):
        result = subprocess.run(["git", "-c", "user.name=Operator", "-c", f"user.email={email}", "-C", self.path, *args],
                                env=FIXTURE_ENV, capture_output=True, text=True)
        assert result.returncode == 0 or not check, (args, result.stderr)
        return result.stdout.strip() if check else result.returncode

    def write(self, content, name="file"):
        pathlib.Path(self.path, name).write_text(content)

    def edit(self, line, text):
        lines = pathlib.Path(self.path, "file").read_text().splitlines()
        lines[line] = text
        self.write("\n".join(lines) + "\n")

    def commit(self, *message, email=OPERATOR, flags=()):
        self.git("add", "-A")
        self.git("commit", "-q", *flags, *[part for line in message for part in ("-m", line)], email=email)
        return self.git("rev-parse", "HEAD")

    def move_target(self, line=None):
        self.git("checkout", "-q", "dev")
        if line is None:
            self.write("target moved\n", name="other")
        else:
            self.edit(line, "target change")
        self.commit("chore: the target moves")
        self.git("checkout", "-q", "topic")

    def carry(self):
        head = self.git("rev-parse", "HEAD")
        source = {"head": self.reviewed, "merge_base": self.base}
        return review.carry_problem(self.path, source, head, self.git("merge-base", "dev", head), [AGENT.upper()])


def two_commits(path):
    fixture = Fixture(path)
    fixture.edit(2, "first change")
    fixture.first = fixture.commit("feat: first")
    fixture.edit(14, "second change")
    fixture.second = fixture.reviewed = fixture.commit("feat: second", "With a body.")
    return fixture


with tempfile.TemporaryDirectory() as tmp:
    os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
    work = os.path.join(tmp, "state", "pr-review", "work", os.uname().nodename)
    # A pure rebase onto a newer target carries, and the merge sandbox is removed.
    fixture = two_commits(os.path.join(tmp, "rebase"))
    fixture.move_target()
    fixture.git("rebase", "-q", "dev")
    assert fixture.carry() == ("rebase", None), fixture.carry()
    assert not os.listdir(work), os.listdir(work)
    # A timed-out git call is a failed carry, never an unhandled exception.
    real_subprocess_run = subprocess.run

    def slow_merge(argv, *args, **kwargs):
        if "merge-tree" in argv:
            raise subprocess.TimeoutExpired(argv, 120)
        return real_subprocess_run(argv, *args, **kwargs)

    with patch.object(review.subprocess, "run", slow_merge):
        try:
            fixture.carry()
        except review.ReviewError as error:
            assert "merge-tree" in str(error), error
        else:
            raise AssertionError("a timed-out merge-tree must fail the carry")
    assert not os.listdir(work), os.listdir(work)

    # Merge drivers named by the clone's own config and attributes never run:
    # here one would report a conflict as clean, keeping the target's line, as
    # the resolution did.
    fixture = Fixture(os.path.join(tmp, "driver"))
    fixture.edit(2, "first change")
    fixture.first = fixture.reviewed = fixture.commit("feat: first")
    fixture.move_target(line=2)
    fixture.git("checkout", "-q", "--detach", "dev")
    fixture.commit(flags=("--allow-empty", "-C", fixture.first))
    marker = os.path.join(tmp, "driver-ran")
    pathlib.Path(fixture.path, ".git", "info").mkdir(exist_ok=True)
    pathlib.Path(fixture.path, ".git", "info", "attributes").write_text("file merge=ours\n")
    fixture.git("config", "merge.ours.driver", f"touch {marker}")
    kind, problem = fixture.carry()
    assert kind == "rebase" and "conflicts" in problem, problem
    assert not os.path.exists(marker), "a repository merge driver ran"

    # The sandbox ignores the system attributes file and uses the clone's
    # object format, so a SHA-256 clone still carries a clean rebase.
    with review.merge_sandbox(fixture.path) as sandbox:
        assert sandbox.env["GIT_ATTR_NOSYSTEM"] == "1"
    fixture = Fixture(os.path.join(tmp, "sha256"), object_format="sha256")
    fixture.edit(2, "first change")
    fixture.reviewed = fixture.commit("feat: first")
    fixture.move_target()
    fixture.git("rebase", "-q", "dev")
    assert fixture.carry() == ("rebase", None), fixture.carry()

    # A conflict resolution needs a review, even when it keeps the PR's line.
    fixture = two_commits(os.path.join(tmp, "conflict"))
    fixture.move_target(line=2)
    assert fixture.git("rebase", "dev", check=False) != 0
    fixture.edit(2, "first change")
    fixture.git("add", "-A")
    fixture.git("rebase", "--continue")
    kind, problem = fixture.carry()
    assert kind == "rebase" and "conflicts" in problem, problem

    # The reviewed patch applied to an identical block elsewhere has the same
    # patch ID, but replaying the reviewed commit gives another tree.
    block = "".join(f"same {number}\n" for number in range(1, 8))
    fixture = Fixture(os.path.join(tmp, "duplicate"), block + "unique 1\nunique 2\nunique 3\nunique 4\n" + block)
    fixture.edit(3, "changed")
    fixture.reviewed = fixture.commit("feat: change the block")
    fixture.move_target()
    fixture.git("checkout", "-q", "--detach", "dev")
    fixture.edit(14, "changed")
    fixture.commit(flags=("-C", fixture.reviewed))
    patch_ids = {subprocess.run(["git", "-C", fixture.path, "patch-id", "--stable"], input=fixture.git("show", sha) + "\n",
                                capture_output=True, text=True, check=True).stdout.split()[0]
                 for sha in (fixture.reviewed, "HEAD")}
    assert len(patch_ids) == 1, patch_ids
    kind, problem = fixture.carry()
    assert kind == "rebase" and "differs from" in problem, problem

    # A whitespace-only change during the rebase needs a review.
    fixture = two_commits(os.path.join(tmp, "whitespace"))
    fixture.move_target()
    fixture.git("checkout", "-q", "--detach", "dev")
    fixture.git("cherry-pick", fixture.first)
    fixture.edit(5, "line 6 ")
    fixture.commit(flags=("--amend", "-C", "HEAD"))
    fixture.git("cherry-pick", fixture.second)
    kind, problem = fixture.carry()
    assert kind == "rebase" and "commit 1" in problem and "differs from" in problem, problem

    # A rebase by someone else changes the committer identity; one by an agent
    # forge account, as a forge-side rebase or branch update, never carries.
    for email, expected in (("someone@example.invalid", "another committer identity"), (AGENT, "agent identity")):
        fixture = two_commits(os.path.join(tmp, email))
        fixture.move_target()
        fixture.git("rebase", "-q", "dev", email=email)
        kind, problem = fixture.carry()
        assert expected in problem, (email, problem)

    # A fold of fixups, nested fixups and fixups naming a commit hash carries.
    fixture = two_commits(os.path.join(tmp, "fold"))
    fixture.edit(3, "fixup change")
    fixture.commit("fixup! feat: first")
    fixture.edit(4, "nested fixup")
    fixture.commit("fixup! fixup! feat: first")
    fixture.edit(5, "hash fixup")
    fixture.reviewed = fixture.commit(f"fixup! {fixture.first[:10]}")
    fixture.git("rebase", "-q", "-i", "--autosquash", fixture.base)
    assert fixture.git("rev-list", "--count", f"{fixture.base}..HEAD") == "2"
    assert fixture.carry() == ("fold", None), fixture.carry()
    # So does a rebase of the folded head, from the carried round.
    fixture.reviewed = fixture.git("rev-parse", "HEAD")
    fixture.move_target()
    fixture.git("rebase", "-q", "dev")
    assert fixture.carry() == ("rebase", None), fixture.carry()

    # A fold that moves a hunk between commits keeps the head's tree, but not the commits'.
    fixture = two_commits(os.path.join(tmp, "moved-hunk"))
    fixture.edit(3, "fixup change")
    fixture.reviewed = fixture.commit("fixup! feat: first")
    fixture.git("checkout", "-q", "--detach", fixture.base)
    for line, text in ((2, "first change"), (3, "fixup change"), (14, "second change")):
        fixture.edit(line, text)
    fixture.commit(flags=("-C", fixture.first))
    fixture.commit(flags=("--allow-empty", "-C", fixture.second))
    assert fixture.git("rev-parse", "HEAD^{tree}") == fixture.git("rev-parse", f"{fixture.reviewed}^{{tree}}")
    kind, problem = fixture.carry()
    assert kind == "fold" and "commit 1" in problem and "fixups folded in" in problem, problem

    # Moving a fixup before a later commit that changed the same line changes
    # what it applies to; a resolution that keeps the final tree still needs a review.
    fixture = Fixture(os.path.join(tmp, "reorder"))
    fixture.edit(2, "a")
    fixture.first = fixture.commit("feat: first")
    fixture.edit(2, "b")
    fixture.second = fixture.commit("feat: second")
    fixture.edit(2, "c")
    fixture.reviewed = fixture.commit("fixup! feat: first")
    assert fixture.git("rebase", "-i", "--autosquash", fixture.base, check=False) != 0
    fixture.git("rebase", "--abort")
    fixture.git("checkout", "-q", "--detach", fixture.base)
    fixture.edit(2, "c")
    fixture.commit(flags=("-C", fixture.first))
    fixture.commit(flags=("--allow-empty", "-C", fixture.second))
    kind, problem = fixture.carry()
    assert kind == "fold" and "conflicts" in problem, problem

    # squash! and amend! change a message, so their folds need a review.
    for message in (("squash! feat: first",), ("amend! feat: first", "feat: first, reworded")):
        fixture = two_commits(os.path.join(tmp, message[0].split("!")[0]))
        fixture.edit(3, "more")
        fixture.reviewed = fixture.commit(*message)
        fixture.git("rebase", "-q", "-i", "--autosquash", fixture.base)
        kind, problem = fixture.carry()
        assert kind == "fold" and "squash! or amend!" in problem, (message, problem)

# git's autosquash order: an unmatched fixup stays where it is, and later
# fixups follow earlier ones of the same commit.
commits = [{"sha": f"{index:040x}", "message": message.encode()} for index, message in enumerate(
    ("feat: a\n", "fixup! nothing\n", "feat: b\n", "fixup! feat: a\n", "fixup! feat\n", "fixup! fixup! feat: a\n"))]
assert review.autosquash_order(commits) == [[0, 3, 4, 5], [1], [2]], review.autosquash_order(commits)

# selftest runs every deep and light reviewer on a built-in change and reports
# why a client failed, in the client's words.
with tempfile.TemporaryDirectory() as tmp:
    tmp = os.path.realpath(tmp)
    bin_dir = os.path.join(tmp, "bin")
    os.makedirs(bin_dir)
    calls = os.path.join(tmp, "calls")
    # Codex's sandbox denies /tmp, so the checkout must sit in the state directory like a real run's.
    in_work = 'case "$PWD" in "$XDG_STATE_HOME"/pr-review/work/*) ;; *) exit 11;; esac; '
    good = {
        "codex": in_work + 'cat >/dev/null; echo codex >>"$SELFTEST_CALLS"; test -f price.py || exit 1; '
                 'while [ "$1" != -o ]; do shift; done; echo "Verdict: blocking findings" >"$2"',
        "claude": in_work + 'cat >/dev/null; echo claude >>"$SELFTEST_CALLS"; grep -q "discount / 10)" price.py || exit 1; '
                  'printf \'{"result": "Verdict: blocking findings\\\\n1. price.py:3"}\'',
    }

    def client(name, body):
        path = os.path.join(bin_dir, name)
        pathlib.Path(path).write_text(f"#!/bin/sh\n{body}\n")
        os.chmod(path, 0o755)

    def selftest(*argv):
        out, err = io.StringIO(), io.StringIO()
        sys.stdout, sys.stderr = out, err
        try:
            return review.main(["selftest", *argv]), out.getvalue() + err.getvalue()
        finally:
            sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__

    def call_count():
        return len(pathlib.Path(calls).read_text().split()) if os.path.exists(calls) else 0

    config = {
        "timeout": 20,
        "reviewers": [
            {"name": "gpt", "client": "codex", "model": "m", "effort": "high"},
            {"name": "opus", "client": "claude", "model": "m", "effort": "high"},
        ],
        # The same Codex reviewer is tested once; the cheaper Claude one too.
        "light_reviewers": [
            {"name": "gpt", "client": "codex", "model": "m", "effort": "high"},
            {"name": "opus", "client": "claude", "model": "m", "effort": "low"},
        ],
    }
    config_path = os.path.join(tmp, "config.json")
    pathlib.Path(config_path).write_text(json.dumps(config))
    # Never fall through to real clients on the developer's PATH.
    system_path = [entry for entry in os.environ["PATH"].split(os.pathsep)
                   if not any(os.path.exists(os.path.join(entry, name)) for name in ("claude", "codex"))]
    environment = {
        "PATH": os.pathsep.join([bin_dir, *system_path]), "XDG_STATE_HOME": os.path.join(tmp, "state"),
        "PR_REVIEW_CONFIG": config_path, "SELFTEST_CALLS": calls,
    }
    status_path = os.path.join(tmp, "state", "pr-review", "selftest", "status.json")
    with patch.dict(os.environ, environment):
        for name, body in good.items():
            client(name, body)
        code, output = selftest()
        assert code == 0, output
        assert sorted(json.loads(pathlib.Path(status_path).read_text())["reviewers"]) == \
            ["deep-gpt", "deep-opus", "light-opus"], output
        assert "deep-opus (claude m high): ok" in output and "light-opus (claude m low): ok" in output, output
        assert call_count() == 3, call_count()

        # --if-stale skips a recent result for the same reviewers and clients...
        code, output = selftest("--if-stale", "24")
        assert code == 0 and "skipping" in output and call_count() == 3, output
        # ...but not after a client changes (a release is a new store path),
        release = os.path.join(tmp, "release")
        os.makedirs(release)
        shutil.copy2(os.path.join(bin_dir, "claude"), release)
        os.environ["PATH"] = release + os.pathsep + os.environ["PATH"]
        code, output = selftest("--if-stale", "24")
        assert code == 0 and "skipping" not in output and call_count() == 6, output
        os.environ["PATH"] = environment["PATH"]
        # a reviewer changes,
        config["reviewers"][0]["effort"] = "xhigh"
        pathlib.Path(config_path).write_text(json.dumps(config))
        code, output = selftest("--if-stale", "24")
        assert code == 0 and call_count() == 10, output
        # or the result gets old.
        status = json.loads(pathlib.Path(status_path).read_text())
        status["finished"] -= 25 * 3600
        pathlib.Path(status_path).write_text(json.dumps(status))
        code, output = selftest("--if-stale", "24")
        assert code == 0 and call_count() == 14, output
        config["reviewers"][0]["effort"] = "high"
        pathlib.Path(config_path).write_text(json.dumps(config))

        # A failed sign-in is reported as the client put it, and fails the test.
        client("claude", 'cat >/dev/null; printf \'{"type":"result","is_error":true,'
                         '"result":"Failed to authenticate: OAuth session expired"}\'; exit 1')
        code, output = selftest()
        assert code == 1, output
        assert "deep-opus (claude m high): failed: Failed to authenticate: OAuth session expired" in output, output
        assert "deep-gpt (codex m high): ok" in output, output
        status = json.loads(pathlib.Path(status_path).read_text())
        assert status["ok"] is False and "OAuth" in status["reviewers"]["deep-opus"]["reason"], status
        # A recent failure is skipped too, so a timer notifies once per change or day.
        code, output = selftest("--if-stale", "24")
        assert code == 0 and "failed" in output and "skipping" in output, output

        # Claude can report its errors in `errors` without a `result`.
        client("claude", 'cat >/dev/null; printf \'{"type":"result","subtype":"error_during_execution",'
                         '"is_error":true,"errors":["API Error: 529 overloaded"]}\'; exit 1')
        code, output = selftest()
        assert code == 1 and "deep-opus (claude m high): failed: API Error: 529 overloaded" in output, output

        # An option a new client no longer knows shows up as its stderr, even
        # when usage text follows the error.
        client("claude", good["claude"])
        client("codex", "cat >/dev/null; echo \"error: unexpected argument '--ignore-rules' found\" >&2; "
                        "echo 'Usage: codex exec [OPTIONS]' >&2; echo \"For more information, try '--help'.\" >&2; exit 2")
        code, output = selftest()
        assert code == 1 and "deep-gpt (codex m high): failed: error: unexpected argument '--ignore-rules' found" in output, output

        # A held lock is a skip for the timer, so it raises no false alarm, but
        # an error for a manual run.
        import fcntl
        lock_path = os.path.join(tmp, "state", "pr-review", "selftest", "lock")
        with open(lock_path, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            status = json.loads(pathlib.Path(status_path).read_text())
            status["finished"] -= 25 * 3600
            pathlib.Path(status_path).write_text(json.dumps(status))
            code, output = selftest("--if-stale", "24")
            assert code == 0 and "already" not in output and "running; skipping" in output, output
            code, output = selftest()
            assert code == 1 and "another pr-review selftest is running" in output, output

        # Codex's JSON error events count as the reason: the last one, since earlier ones may have been retried.
        client("codex", 'cat >/dev/null; printf \'{"type":"error","message":"Reconnecting... 1/5"}\\n'
                        '{"type":"turn.failed","error":{"message":"Selected model is at capacity."}}\\n\'; exit 1')
        code, output = selftest()
        assert code == 1 and "failed: Selected model is at capacity." in output, output

        # A reply without a verdict is not a review, whatever notices or retried errors came before it.
        client("codex", 'cat >/dev/null; echo "Reading prompt from stdin..." >&2; '
                        'printf \'{"type":"error","message":"Reconnecting... 1/5"}\\n\'; '
                        'while [ "$1" != -o ]; do shift; done; echo "I could not open the file." >"$2"')
        client("claude", "cat >/dev/null; printf '{\"result\": \"I could not open the file.\"}'")
        code, output = selftest()
        assert code == 1 and "deep-opus (claude m high): failed: replied without a verdict: I could not open the file." in output, output
        assert "deep-gpt (codex m high): failed: replied without a verdict" in output, output

        # A result pr-review cannot parse is named as such, not as a reply without a verdict.
        client("claude", "cat >/dev/null; printf '{\"answer\": \"Verdict: no findings\"}'")
        code, output = selftest()
        assert code == 1 and "deep-opus (claude m high): failed: cannot read the reviewer result: no string result" in output, output

        # Sign-in failures worded without "error" still count as the reason.
        client("codex", 'cat >/dev/null; echo "Not logged in. Please run codex login" >&2; echo "Bye." >&2; exit 1')
        code, output = selftest()
        assert code == 1 and "deep-gpt (codex m high): failed: Not logged in. Please run codex login" in output, output

        # A crash after a notice reports the exit status, not the notice.
        client("codex", 'cat >/dev/null; echo "Reading prompt from stdin..." >&2; exit 137')
        code, output = selftest()
        assert code == 1 and "deep-gpt (codex m high): failed: exited with status 137" in output, output

        # A missing client is reported, not a crash.
        os.remove(os.path.join(bin_dir, "claude"))
        code, output = selftest()
        assert code == 1 and "deep-opus (claude m high): failed: cannot start claude" in output, output

        # A stalled client times out within the configured limit.
        client("claude", good["claude"])
        client("codex", "sleep 30")
        config["timeout"] = 1
        pathlib.Path(config_path).write_text(json.dumps(config))
        started = time.monotonic()
        code, output = selftest()
        assert time.monotonic() - started < 10, output
        assert code == 1 and "deep-gpt (codex m high): timeout: no reply within" in output, output

assert review.failure_reason({"status": "failed", "exit": 3, "seconds": 1, "reviewer": {"client": "codex"},
                              "output": "/nonexistent/gpt.md"}) == "exited with status 3"

os.environ.pop("PR_REVIEW_CONFIG", None)  # its temporary file is gone
subprocess.run([sys.executable, str(ROOT / "scripts/checks/test-pr-review-substitutions.py")], check=True)
print("pr-review tests passed")
