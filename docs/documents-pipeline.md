# Documents Pipeline — Home-Manager Module

## Overview

The `services.documents` module manages two coordinated systemd user services
that form the local side of the Documents → Paperless ingestion pipeline.

```
~/Documents/                            (your filesystem, always intact)
     │
     │  file lands at root
     ▼
documents-organizer                     (watches ~/Documents root only)
     │  moves to type/YYYY/MM/
     ▼
~/Documents/pdf/2026/04/invoice.pdf
~/Documents/images/2026/03/scan.jpg
~/Documents/misc/2026/04/archive.zip    (not ingested)
     │
     │  any supported file anywhere in ~/Documents
     ▼
documents-ingest                        (watches ~/Documents recursively)
     │  copies to ingest dir, preserving relative path
     ▼
~/paperless-ingest/
     │
     ▼
Paperless-NGX (consumes, deletes from ingest dir, indexes)
```

`~/Documents` is never modified by the ingest step — files stay there
permanently. Paperless receives a disposable copy and classifies documents
based on content via its Auto classifier.

---

## Service: `documents-organizer`

Watches the **root of `~/Documents` only** (non-recursive) using `inotifywait`.

Triggers on: `IN_CLOSE_WRITE`, `IN_MOVED_TO`

When a file lands at the root, it is moved into a type bucket and
chronological subdirectory based on the file's modification time:

```
~/Documents/
    pdf/YYYY/MM/
    images/YYYY/MM/
    docx/YYYY/MM/
    xlsx/YYYY/MM/
    misc/YYYY/MM/    ← not ingested into Paperless
```

Filenames are preserved as-is. The date reflects when the file was last
modified, not when the organizer ran.

| Bucket   | Extensions                              |
|----------|-----------------------------------------|
| `pdf`    | pdf                                     |
| `images` | jpg, jpeg, png, gif, webp, tiff, tif    |
| `docx`   | docx, doc, odt, rtf                     |
| `xlsx`   | xlsx, xls, ods                          |
| `misc`   | everything else                         |

Files placed directly into subdirs are not touched by this service.

---

## Service: `documents-ingest`

Watches **all of `~/Documents` recursively** using `inotifywait`.

Triggers on: `IN_CLOSE_WRITE`, `IN_MOVED_TO`

When a supported file appears anywhere in Documents — whether placed by the
organizer into a type subdir, or dropped directly into any subdir by the
user — it is copied to the ingest directory preserving the relative path.

Supported extensions: `pdf`, `jpg`, `jpeg`, `png`, `gif`, `webp`, `tiff`,
`tif`, `docx`, `odt`, `xlsx`

`misc/` files are never copied.

---

## Deduplication

No file is re-ingested on subsequent runs because:

1. **Event-driven** — `inotifywait` fires only when files are newly written or
   moved in. Files already present in Documents at service start are not seen.
   Only genuinely new arrivals trigger a copy.

2. **Paperless content hashing** — Paperless computes a SHA256 of each
   document on ingestion. Identical content is silently skipped even if the
   ingest dir somehow receives a duplicate copy.

---

## Module Location

```
modules/home-manager/services/documents/default.nix
```

## Enabling in a Host Config

```nix
# users/alc/linux/xyz.nix
imports = [
  "${configDir}/modules/home-manager/services/documents/default.nix"
];

services.documents.enable = true;
```

Default paths (`~/Documents` and `~/paperless-ingest`) are used unless
overridden via module options.

## Logs

```bash
journalctl --user -u documents-organizer -f
journalctl --user -u documents-ingest -f
```

---

## Future Work

- **Storage path configuration** — a dedicated review of Paperless storage
  paths and entity taxonomy is planned as a separate session. See
  `gitops/tools/paperless/docs/pipeline.md`.

## Related

- Paperless consume folder configuration:
  `gitops/xyz/paperless/arq_alcxyz/compose.yml`
- Paperless pipeline documentation:
  `gitops/tools/paperless/docs/pipeline.md`
