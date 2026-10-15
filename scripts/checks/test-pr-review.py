"""Contract tests for pr-review and the agent PR review guard hook."""

import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "pr_review", ROOT / "modules/home-manager/programs/ai/pr-review.py"
)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
real_run = review.run
real_forgejo = review.forgejo_request

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

    # Fake reviewer CLIs: codex writes its -o file and reports its model on
    # stderr; claude prints a JSON result with per-model usage to stdout.
    bin_dir = os.path.join(tmp, "bin")
    os.mkdir(bin_dir)
    scripts = {
        "codex": 'cat >/dev/null; case "$*" in *"mcp_oauth_credentials_store=\\"file\\""*"--ignore-user-config --ignore-rules --disable apps --json"*) ;; *) exit 3;; esac; '
                 'test -z "$FORGEJO_API_TOKEN_FILE$GH_TOKEN" || exit 4; '
                 'printf "OpenAI Codex\\n--------\\nmodel: gpt-reported\\n--------\\nuser\\nmodel: gpt-spoofed\\n" >&2; '
                 'printf \'{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":9}}\\n\'; '
                 'while [ "$1" != -o ]; do shift; done; test -f file && echo "Verdict: no findings" >"$2"',
        "claude": 'cat >/dev/null; test -f file || exit 1; test ! -L link || exit 5; test ! -e sub/.GIT || exit 7; '
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
    prompt = pathlib.Path(state, "prompt.md").read_text()
    assert "+{braces} survive" in prompt and "+one" not in prompt, prompt
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
    assert f"### Round at {first[:12]} (full)" in prompt and "#### gpt\n\nVerdict: no findings" in prompt, prompt
    interdiff, whole = prompt.split("## Interdiff")[1].split("## Full PR diff")
    assert "+fixed" in interdiff and "+{braces}" not in interdiff and "+{braces} survive" in whole, prompt
    assert os.path.exists(pathlib.Path(rounds, head, "status.json")), "earlier rounds are kept"

    # --force on a follow-up repeats the follow-up.
    code, output = cli("run", "4", "--force", "--response", "fixed the parser.")
    assert code == 0 and f"(follow-up to {first[:12]})" in output, output

    # Later follow-ups see every round since the full review; at most
    # MAX_FOLLOW_UPS run in a row.
    for count in (2, 3):
        fix = push(f"one\n{{braces}} survive\nfixed {count}\n", fix)
        assert review_round(fix, "(follow-up to").startswith("follow-up to")
        assert (state_of(fix)["followups"], state_of(fix)["root"]) == (count, first)
    prompt = pathlib.Path(rounds, fix, "prompt.md").read_text()
    assert prompt.count("### Round at") == 3 and "Author's response before this round:\n\nfixed the parser." in prompt
    fix = push("one\n{braces} survive\nfixed 4\n", fix)
    assert review_round(fix, "(full review: 3 follow-ups in a row)") == "full"

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

    # A large or binary change, a rebase, merging the target in, a retarget
    # or changed reviewers each need a full review.
    fix = push("one\n{braces} survive\n" + "more\n" * 60, fix)
    review_round(fix, "(full review: more than 40 lines changed since")
    binary = git_out("hash-object", "-w", "--stdin", stdin="\0binary\n")
    fix = push("one\n", fix, extra=f"100644 blob {binary}\tblob.bin\n")
    review_round(fix, "(full review: binary files changed since")
    dev = git_out("rev-parse", "origin/dev")
    fix = push("rebased\n", dev, files=fix)
    review_round(fix, "(full review: the head does not descend from")
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

subprocess.run([sys.executable, str(ROOT / "scripts/checks/test-pr-review-substitutions.py")], check=True)
print("pr-review tests passed")
