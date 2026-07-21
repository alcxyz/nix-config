# Visual reports

Markdown and ADRs remain the durable source of truth. The standalone HTML
reports in this directory are the summary-first presentation layer used during
interactive testing and review.

Each report is one self-contained HTML file with inline CSS and optional
vanilla JavaScript. It must remain understandable without JavaScript, external
fonts, remote assets, or a frontend build step. The format is repository
agnostic: reports may live in this repository, the GitOps repository, or any
other project that needs an accessible presentation layer over durable
Markdown evidence.

The latest completed report is the living template. Copy it into the consuming
repository for a new campaign and replace the masthead, verdict, result rows,
evidence, defects, method, limits, and actions. Keep the design tokens, status
language, breakpoints, and section order consistent. The report belongs beside
the evidence it summarizes; the viewer does not require the report to live in
`nix-config`.

## Status language

- `PASS` is a measured test outcome.
- `DEFAULT` is a recommendation and should appear exactly once.
- `VISUAL DEFECT` qualifies a pass without changing it into a failure.
- `FAIL` means an acceptance condition was not met.

Every status uses a glyph, a text label, and a distinct border treatment. Color
is supporting information only.

## View a report

After rebuilding Home Manager, `nixbox-report` is available on every configured
user machine and accepts a report from any checkout:

```sh
nixbox-report docs/reports/2026-07-21-remote-browser-streaming.html
nixbox-report ~/src/infra/gitops/docs/reports/example.html
```

That binds to loopback, opens the local default browser, and serves only the
selected file. To view it from another machine on the same LAN:

```sh
nixbox-report --lan --no-open docs/reports/2026-07-21-remote-browser-streaming.html
```

The command binds to the private address selected by the default route and
prints the URL. Use `--bind ADDRESS` when a machine has multiple physical
networks and the desired address should be explicit. Stop the temporary server
with `Ctrl+C`.

Before Home Manager is rebuilt, the same viewer can run directly from the
flake:

```sh
nix run .#nixbox-report -- docs/reports/2026-07-21-remote-browser-streaming.html
```

From a different checkout, point `nix run` at this flake and pass the report's
local path. Installing the package through the shared Home Manager package set
is preferred for regular use because the same command then works in every
repository.

## Acceptance checklist

- Summary and recommendation are visible before raw telemetry.
- Body text remains readable from the couch at a 1440p TV viewport.
- The comparison linearizes without horizontal scrolling below 1024 px.
- Keyboard focus is visible and the skip link works.
- Dark, light, reduced-motion, no-JavaScript, and print views remain usable.
- A grayscale view still communicates every status.
- No private endpoint, credential, pairing material, or runtime identifier is
  copied into a public report.
