"""Focused shell expansion and subshell scope regressions, without live clients."""

import importlib.util
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "pr_review_substitutions", ROOT / "modules/home-manager/programs/ai/pr-review.py"
)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)

HEAD = "0123456789abcdef0123456789abcdef01234567"
PINNED = f"Automated read-only review ({HEAD[:12]} on dev): no blocking findings."
calls = []


def fake_run(argv, cwd=None, **kwargs):
    assert argv[:3] == ["gh", "pr", "view"], argv
    number = argv[3]
    calls.append((number, cwd))
    return json.dumps({"bodies": [PINNED] if number == "7" else [],
                       "head": HEAD, "base": "dev", "url": f"https://github.com/o/r/pull/{number}"})


def fake_info(pr):
    calls.append((pr.number, None))
    return {"head": HEAD, "base": "dev"}


review.run = fake_run
review.pr_info = fake_info
review.comment_bodies = lambda pr: [PINNED] if pr.number == "7" else []


def expect(command, blocked, lookups=True):
    calls.clear()
    try:
        problem = review.guard_check(command, "/work")
    except review.ReviewError as error:
        problem = str(error)
    assert bool(problem) == blocked, (command, problem)
    assert bool(calls) == lookups, (command, calls, problem)
    return list(calls)


# Expansions execute before ordinary prose commands, assignment-only commands,
# and redirections. The outer command's text exemption cannot suppress them.
for number in ("7", "9"):
    for command in (
        f'echo "$(gh pr merge {number})"',
        f'echo $(gh pr merge {number})',
        f'git commit -m "$(gh pr merge {number})"',
        f'echo "prefix$(gh pr merge {number})suffix"',
        f'echo `gh pr merge {number}`',
        f'echo "`gh pr merge {number}`"',
        f'response="$(gh pr merge {number})"',
        f'response=`gh pr merge {number}`',
        f'echo $(echo "$(gh pr merge {number})")',
        f'echo `echo \\`gh pr merge {number}\\``',
        f'cat >"$(gh pr merge {number})"',
        f'cat <<< "$(gh pr merge {number})"',
        f'cat pre<(gh pr merge {number})post',
        f'response="$(tea api -X POST /repos/o/r/pulls/{number}/merge -d \'{{}}\')"',
    ):
        expect(command, number == "9")

# Single quotes and escaped expansion markers are literal shell data.
for command in (
    "echo '$(gh pr merge 9)'",
    "echo '`gh pr merge 9`'",
    "response='$(tea api -X POST /repos/o/r/pulls/9/merge)'",
    'echo "\\$(gh pr merge 9)"',
    'echo "\\`gh pr merge 9\\`"',
    "cat <<'EOF'\n$(gh pr merge 9)\n`gh pr merge 9`\nEOF",
    "cat <<< '$(gh pr merge 9)'",
):
    expect(command, False, False)

# Quoted heredoc prose inside a substitution can contain arbitrary quotes,
# parentheses and merge syntax. It is not part of the surrounding shell word.
body = "It's prose: gh pr merge 9; $(gh pr merge 9)\nodd \" quote ) ( ` and tea pulls merge 9"
for delimiter, indent in (("'EOF'", ""), ('"EOF"', ""), ("'EOF'", "\t")):
    operator = "<<-" if indent else "<<"
    text = "\n".join(indent + line for line in body.splitlines())
    command = f'git commit -m "$(cat {operator}{delimiter}\n{text}\n{indent}EOF\n)"'
    expect(command, False, False)
expect('git commit -m "$(cat <<A <<\'B\'\nplain merge prose\nA\nIt\'s ) prose gh pr merge 9\nB\n)"', False, False)
expect('git commit -m "$(cat <<\'EOF\'\nIt\'s ) prose\nEOF\ngh pr merge 9\n)"', True)
expect('git commit -m "$(cat <<EOF\n\'$(gh pr merge 9)\'\nEOF\n)"', True)
expect('git commit -m "$(cat <<EOF\n`gh pr merge 9`\nEOF\n)"', True)

# Substitutions and grouped subshells inherit cwd, and their cd stays local.
for command in (
    'echo "$(cd child && gh pr merge 7)"; gh pr merge 7',
    'echo `cd child && gh pr merge 7`; gh pr merge 7',
    '(cd child && gh pr merge 7); gh pr merge 7',
    '( (cd child && gh pr merge 7)); gh pr merge 7',
    'cat <(cd child && gh pr merge 7); gh pr merge 7',
):
    assert expect(command, False) == [("7", "/work/child"), ("7", "/work")], command
assert expect('cd outer && echo "$(cd child && gh pr merge 7)" && gh pr merge 7', False) == [
    ("7", "/work/outer/child"), ("7", "/work/outer")
]

# A cd that failed or was skipped can leave the merge in a different repo.
# Refuse ambiguous cwd rather than authorizing one possible repository.
for command in (
    'cd child; gh pr merge 7',
    '(cd child; gh pr merge 7); gh pr merge 7',
    'false && cd child; gh pr merge 7',
    'true || cd child; gh pr merge 7',
    'cd child && echo ok; gh pr merge 7',
    'if true; then cd child; fi; gh pr merge 7',
    'cd child | cat; gh pr merge 7',
):
    expect(command, True, False)
assert expect('command cd child && gh pr merge 7', False) == [("7", "/work/child")]
assert expect('builtin cd child && gh pr merge 7', False) == [("7", "/work/child")]
assert expect('cd child || gh pr merge 7', False) == [("7", "/work")]

print("pr-review substitution tests passed")
