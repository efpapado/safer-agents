# connection_logs

One file per run, named by tool and by the time the run finished:

    claude-2026-08-25T14-03-12.log
    codex-2026-08-25T15-20-44.log
    opencode-2026-08-25T16-01-09.log

The prefix is the tool, so one command's history is easy to read on its own:

    ls connection_logs/opencode-*

## What is in them

**Blocked connection attempts only.** Destinations the agent tried to reach that
were on neither `../proxy/allowlist-common.txt` nor its own
`../proxy/allowlist-<tool>.txt`.

Successful connections are not recorded. That is not a filtering step — the
gatekeeper is configured with `LogLevel Notice`, and successful connections are
logged at a more detailed level than that, so they are never written down in the
first place. The log tells you what was refused, not what the agent read.

Each file has these parts:

1. A header: when, which tool, which project folder, which allowlists — and
   every folder the agent could WRITE to. Extra folders are read-only unless
   you gave `--rw`, so that short list is the whole set of places on your Mac
   that could have changed during the run.
2. **BLOCKED HOSTS** — each refused hostname with a count, most frequent first.
   This is the part to read.
3. **REFUSED OLLAMA REQUESTS** — only for `safer-opencode --ollama`. Requests to
   the local model server that were not inference: model downloads, uploads,
   deletions. Method and path only; never a request body. One of these is worth
   investigating — normal editing work never asks for them.
4. **RAW PROXY MESSAGES** — everything the gatekeeper reported. A few startup
   lines are normal. Kept so that a real proxy fault is visible rather than
   silently filtered away.

## What these files do NOT tell you

With `safer-opencode --ollama`, a cloud-backed model (`-cloud`) makes **your Mac**
connect to ollama.com and send the prompt. That connection is not the
container's, so nothing here records it and no allowlist governs it. An empty log
is not proof that nothing left. `../proxy/ollama.conf` explains what this
leaves open and what you can do about it.

## How to use them

Read a few after a week of normal work. Frequency and recency do the arguing:

    api.drupal.org              23 attempts   -> probably needed
    raw.githubusercontent.com    1 attempt    -> look into it before allowing

To allow a host permanently, add an anchored pattern to one of two files:

    ../proxy/allowlist-common.txt     all three commands
    ../proxy/allowlist-<tool>.txt     just that one

Put general-purpose sites in the common file. Keep a tool's own file for its own
service — its model API and its login host — so that, for example, claude cannot
reach OpenAI's servers.

To try a host for a single run:

    safer-claude --allow api.drupal.org

Read the two rules at the top of `allowlist-common.txt` before adding anything.

## Housekeeping

The newest 30 files **per tool** are kept and older ones are deleted
automatically. Per tool, so a busy week of one command does not delete another's
history. Change `LOG_KEEP` in `../lib/safer-common.sh` to keep more or fewer.

This folder must never be mounted into the container — an agent that can edit
these files can erase the record of what it tried. Each command refuses to run
with its working directory anywhere inside the launcher folder, and `--add` and
`--ro` refuse it too.
