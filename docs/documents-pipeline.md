# Documents Pipeline: Home Manager Module

## Overview

The `services.paperflow` module runs [paperflow](https://github.com/alcxyz/paperflow),
the local side of the Documents to Paperless ingestion pipeline. One process
watches a directory, sorts new files into `<type>/<year>/<month>/` folders by
type and modification time, and optionally hands ingestible files to
Paperless-ngx.

```
~/Documents/invoice.pdf                 (a file lands in the watch directory)
     │
     ▼  paperflow sorts by type and file date
~/Documents/pdf/2026/04/invoice.pdf     (stays here permanently)
     │
     ▼  paperflow ingests, when enabled
~/paperless-ingest/invoice.pdf          (ingest = "directory")
POST /api/documents/post_document/      (ingest = "api")
```

The type buckets, exclude patterns and other sorting behaviour belong to
paperflow and its own configuration; see the paperflow README.

## Module Location

```
modules/home-manager/services/paperflow/default.nix
```

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Run paperflow as a user service |
| `watchDir` | `~/Documents` | Directory to watch |
| `ingest` | `"none"` | `"directory"`, `"api"` or `"none"` (sorting only) |
| `ingestDir` | `~/paperless-ingest` | Paperless consume directory, for `ingest = "directory"` |
| `paperlessUrl` | `""` | Paperless-ngx base URL, for `ingest = "api"` |
| `paperlessTokenFile` | `""` | File holding the Paperless API token, for `ingest = "api"` |

Ingestion is off by default: set `ingest` explicitly to send files to
Paperless.

## Enabling in a Host Config

```nix
imports = [
  "${configDir}/modules/home-manager/services/paperflow/default.nix"
];

services.paperflow = {
  enable = true;
  ingest = "directory";
};
```

On Linux the module defines one systemd user service, `paperflow`. On macOS it
defines a launchd agent of the same name. Only the Linux service passes
`--ingest-dir`, so directory ingestion on macOS uses paperflow's own
configuration.

## Logs

```bash
# Linux
journalctl --user -u paperflow -f

# macOS
tail -f ~/Library/Logs/paperflow.log
```
