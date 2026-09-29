# LAMP exploit scripts

These are the scripts used while turning the FAUST CTF 2026 LAMP service from
"why is the web server written in XeLaTeX?" into an automated flag harvester.

They are preserved as **Attack/Defense CTF artifacts** for the authorized FAUST
CTF competition environment. They are not intended as general Internet tooling.

## Files

- `lamp-brrr.sh`  multi-team harvester. Creates newline carriers, triggers the
  tiny stored-TeX RCE, retrieves the result through the `Path:` traversal,
  extracts flags, and can submit batches to MOTH.
- `lamp-probe.sh`  lightweight fleet probe. Registers a fresh account and uses
  `id>/qTEAM` as a canary to classify a target as vulnerable, patched, or unable
  to register.
- `lamp-loop.sh`  continuous A/D wrapper. Re-probes periodically, harvests only
  currently vulnerable teams, remembers already-submitted flags, and feeds new
  ones to MOTH.
- `archive/lamp-brrr-v2.sh`  the second preserved competition copy. It was
  byte-identical to the first one. Yes, we apparently saved the same gremlin
  twice.

## Requirements

The scripts expect a Linux shell with common CTF tooling such as `bash`, `curl`,
`jq`, `grep`, `sort`, `perl`, and the other commands checked by each script.

Set your own team before running anything:

```bash
export OWN_TEAM=123
```

For MOTH submission, provide the endpoint and token through the environment:

```bash
export MOTH_URL='http://127.0.0.1:8001'
export MOTH_API_TOKEN='...'
```

The token is intentionally **not** stored in this repository. We learned at
least one normal lesson during all of this.

## Harvester

Dry-ish run without submitting flags:

```bash
SUBMIT=0 ./lamp-brrr.sh
```

Limit execution to specific team IDs:

```bash
ONLY_TEAMS='45,451' SUBMIT=0 ./lamp-brrr.sh
```

Enable MOTH submission only after the environment variables are configured:

```bash
SUBMIT=1 ./lamp-brrr.sh
```

## Probe

`lamp-probe.sh` expects a newline-separated list of team IDs:

```text
45
451
...
```

Then:

```bash
TARGET_FILE=lamp-teamids.txt ./lamp-probe.sh
```

The probe writes three result lists into a temporary directory:

```text
vulnerable.txt
patched.txt
regfail.txt
```

## Continuous loop

With the probe target file present and both scripts executable:

```bash
./lamp-loop.sh
```

Persistent state lives under:

```text
~/.lamp-brrr/
```

including `seen.flags`, the latest vulnerable-team list, and run logs.

## Exploit chain

The automation glues together four bugs/behaviours documented in the report:

```text
Path header overwrite
        ↓
arbitrary file read
        ↓
stored TeX injection in components.type
        ↓
XeLaTeX shell escape / container-root RCE
        ↓
newline-injected ship file as long-command carrier
        ↓
recent /storage state → flags → MOTH
```

The code quality reflects an Attack/Defense CTF where the target changes while
you are debugging it. Please grade the gremlin accordingly.
