# safer-agent

> **Experimental.** This project is not finished and not proven. Read it before
> you trust it, and treat every control in it as something to verify rather than
> to rely on.
>
> It was written with the help of agentic coding tools: mostly Claude, less
> Codex CLI, and open models through opencode with Ollama for further security
> assessment. That is worth knowing for two reasons. The tools reviewed their
> own sandbox, so the blind spots of one may be the blind spots of the review.
> And the code is what the comments say it is only where somebody checked.

Run Claude Code, Codex or opencode on your project without giving them your Mac.

`safer-agent` is three wrapper commands. Each one starts its coding agent inside
a Docker container that can edit your project and can do very little else. Your
files change. Your machine does not.

```
safer-claude          # Claude Code
safer-codex           # Codex
safer-opencode        # opencode
```

Run one from the folder you want to work in. That folder is mounted read-write,
because the agent has to edit your code. Everything else is closed.

---

## Why

A coding agent runs commands. That is what makes it useful, and it is also the
problem. Three things can go wrong, and they are not the same thing:

1. **The agent runs code on your Mac now.** The container stops this. It has no
   privileges, no root, and a read-only filesystem.

2. **The agent writes a file that runs code on your Mac later.** A hook in
   `.githooks` fires at your next commit. A `.envrc` fires when you `cd` into
   the folder. A `postinstall` script in `package.json` fires at your next
   install. These are files, not commands, so a container does not stop them.
   `dangerous-paths.txt` covers the ones that can be covered, and the exit scan
   reports the ones that cannot.

3. **The agent sends your code out, or fetches instructions in.** The container
   sits on a sealed network. Its only route out is a gatekeeper that allows a
   short list of hostnames and refuses everything else, and every refusal is
   logged.

The first is the easy one. Most of this project is the other two.

---

## Requirements

| | |
|---|---|
| macOS | This is what it is built and tested for. It uses the login Keychain to seed credentials, and Docker Desktop's path sharing. |
| Docker Desktop | Running. The commands build their own images and never download one. |
| Bash | The commands run under `bash`, not `sh`. The stock macOS `/bin/bash` is enough — they avoid bash 4 syntax on purpose. |
| The agent itself, installed on your Mac | `claude`, `codex` or `opencode` must be on your `PATH`. The launcher reads its version and builds an image with the same one, so the sandbox matches what you use. |

You do **not** need to be logged in inside the container. `safer-claude` seeds
the token from your Keychain. See [Logging in](#logging-in).

---

## Install

There is nothing to compile and nothing to install into your system.

```bash
git clone <this repository> ~/tools/safer-agent
cd ~/tools/safer-agent
chmod +x safer-claude safer-codex safer-opencode
```

Put the folder on your `PATH`:

```bash
echo 'export PATH="$HOME/tools/safer-agent:$PATH"' >> ~/.zshrc
exec zsh
```

The commands find their own library, image recipes and lists relative to
themselves, so the folder can live anywhere. Keep the four parts together:
`safer-*`, `lib/`, `docker/` and `proxy/`.

---

## Getting started

```bash
cd ~/projects/my-site
safer-claude
```

The first run builds the agent image and the gatekeeper image. That takes a few
minutes. Later runs start in seconds, and rebuild only when the tool on your Mac
changes version or when you edit a `Dockerfile`.

While it starts, it tells you what it did:

```
Config: throwaway copy — settings changed in the sandbox do not persist.
History for this project: /Users/you/.claude/projects/-Users-you-projects-my-site
Placeholders: 29 empty files and folders are created in the
              mounted trees so the agent cannot create them. They are
              removed when the session ends. See dangerous-paths.txt.
Network: sealed, outbound only through the gatekeeper.
Allowed destinations:
  ^api\.anthropic\.com$
  ^platform\.claude\.com$
  ...
```

Then the agent starts, and you use it exactly as you always do.

When you quit, it tells you what happened:

```
No blocked connections this run.
Log: /Users/you/tools/safer-agent/connection_logs/claude-2026-08-27T14-02-11.log

NEW AUTO-RUN CANDIDATES
-----------------------
  New executable files (1):
    /Users/you/projects/my-site/scripts/deploy.sh
```

Read that last section before you commit. It lists files that appeared during
the session and can run something on your Mac later. Nothing there was blocked —
it is a report, not a refusal.

### Your first session, in order

1. `cd` into a project. Never run these commands from the launcher's own folder;
   they refuse it.
2. Run `safer-claude`. Wait for the build.
3. Work as usual.
4. Quit. Read the exit report.
5. Review the diff on your Mac before you commit. That step is not optional —
   see [What this does not protect you from](#what-this-does-not-protect-you-from).

---

## Usage

```
safer-claude   [--add PATH] [--rw PATH] [--allow HOST] [--effort LEVEL] [--offline] [-- COMMAND ...]
safer-codex    [--add PATH] [--rw PATH] [--allow HOST] [--offline] [-- COMMAND ...]
safer-opencode [--add PATH] [--rw PATH] [--allow HOST] [--ollama] [--offline] [-- COMMAND ...]
```

| Flag | What it does |
|---|---|
| `--add PATH` | Mount another folder **read-only**. `--ro` is the same flag. Use it for reference material: a contrib module, a library's source. |
| `--rw PATH` | Mount another folder **read-write**. The agent can change your Mac through it. A folder outside your project must be confirmed by typing `yes`. |
| `--allow HOST` | Allow one more destination, for this run only. |
| `--offline` | No network at all. The strongest mode, and the right one for a read-only analysis pass. |
| `--effort LEVEL` | `safer-claude` only. `low`, `medium`, `high`, `xhigh` or `max`. Overrides `/effort` for the whole session, so leave it off for interactive work. |
| `--ollama` | `safer-opencode` only. Reach the Ollama server on your Mac. Inference and read-only queries pass; model downloads, uploads and deletions are refused. |
| `-- COMMAND ...` | Run something else instead of the agent. `-- bash` gives you a shell in the sandbox, which is the fastest way to see what the agent can see. |

### Environment variables

| | |
|---|---|
| `SAFER_DEBUG=1` | Print the assembled `docker run` arguments, one per line, then run. |
| `SAFER_DEBUG=2` | Print them and stop. Nothing starts. |
| `SAFER_ASSUME_YES=1` | Answer the `--rw` confirmation. For unattended runs only. |

### Examples

```bash
# A contrib module the agent should read but not touch.
safer-claude --add ../contrib/webform

# Look inside the sandbox yourself.
safer-claude --offline -- bash

# opencode against a local model, with no internet at all.
safer-opencode --ollama --offline
```

---

## What is protected, and how

### Your machine, during the session

The container runs with `--cap-drop ALL`, `--security-opt no-new-privileges`, a
read-only root filesystem, and your own user id rather than root. There is no
`--privileged` and no Docker socket. Git is removed from the image and the build
fails if it comes back.

### Your machine, after the session

Two different mechanisms, because the problem has two halves.

**The tool's own config is a throwaway copy.** The container gets a copy of
`~/.claude` (or `~/.codex`, `~/.config/opencode`), and only what genuinely has
to be shared is bound back. Your Mac never reads that copy, so a hook the agent
writes into it dies with the session. This is default-deny: anything not
explicitly shared is simply not shared.

**The project folder is a list.** A copy will not work here, because the point
of the mount is that the agent's work reaches your Mac. So the auto-run paths
inside a code tree — `.githooks`, `.envrc`, `.vscode`, `.npmrc`, `Makefile`,
project-level agent settings, CI definitions — are covered read-only, and the
absent ones are pre-empted so the agent cannot create them either.

That second half is a blocklist, and a blocklist is never finished. So the
session ends with a scan that reports what a list cannot cover: new files deep
in the tree, names nobody predicted, and changes to files the agent must be
allowed to edit.

### Your data

The container is on an internal Docker network with no route out. A gatekeeper
container (tinyproxy, default-deny) is the only door, and it allows a short list
of hostnames per tool. DNS goes through it too, which closes DNS tunnelling.
Refusals are logged to `connection_logs/`; successful connections are
deliberately not recorded.

The container also cannot reach your Mac's own services, sibling containers, or
your VPN.

---

## What this does not protect you from

Read this part. The rest of the README is the good news.

- **Code you run yourself.** If the agent edits a source file and you later run
  that file, that is execution you opted into. Only review catches it.
- **Prompt injection from code already in the repository.** Mounted code may
  carry instructions aimed at the agent. Nothing here changes that.
- **Files the agent must be allowed to edit.** `package.json` and
  `composer.json` can carry install scripts. They are reported at exit, never
  covered. Install with `npm ci --ignore-scripts` and
  `composer install --no-scripts` as a habit.
- **Deep paths and unpredictable names.** A `.vscode/tasks.json` written five
  folders down, or a `something.code-workspace` invented mid-session, cannot be
  pre-empted. They appear in the exit report instead.
- **Symlinks.** The agent can leave a symlink in your project that points
  somewhere else. A later host process that follows it acts on the target.
- **Anything you put in a prompt.** That reaches the model provider under your
  own account.

The single habit that covers most of this: **read the diff on your Mac before
you commit, and read the exit report first.** Use `git status --ignored` — the
agent can write `.gitignore`.

---

## Logging in

`safer-claude` seeds the token from your macOS Keychain, so a session starts
authenticated. Renewal happens inside the container and is discarded at exit;
your Keychain is never reachable from the container.

If no token is found, run `/login` inside the sandbox. There is no browser in
the image, so use the manual code paste.

---

## Layout

```
safer-claude                  one command per tool. Each holds only that
safer-codex                   tool's own flags, config strategy, image
safer-opencode                and allowlist.

lib/safer-common.sh           the sandbox machinery, shared by all three.

dangerous-paths.txt           paths the agent may not write, in any mounted
                              tree.                        <- edit this one

docker/Dockerfile.claude      one agent image per tool. Nearly identical;
docker/Dockerfile.codex       they differ in the npm package installed last.
docker/Dockerfile.opencode
docker/Dockerfile.proxy       the gatekeeper (tinyproxy).  Shared.
docker/Dockerfile.forwarder   the Ollama forwarder (nginx). opencode only.

proxy/allowlist-common.txt    destinations for all three.  <- edit this one
proxy/allowlist-claude.txt    that tool's own service only
proxy/allowlist-codex.txt
proxy/allowlist-opencode.txt
proxy/tinyproxy.conf          gatekeeper configuration
proxy/ollama.conf             the forwarder's default-deny rules

connection_logs/              <tool>-<timestamp>.log, the newest 30 per tool
connection_logs/README.md     how to read them
```

---

## Configuring it

Two files are meant to be edited. They are shaped differently on purpose.

**`proxy/allowlist-*.txt` is an allowlist.** Anything not named is refused, so
it fails safe when it is out of date. Add an anchored pattern such as
`^www\.example\.com$`. Read the rules at the top of `allowlist-common.txt`
first — some hosts are dangerous to allow no matter how reputable they look.

**`dangerous-paths.txt` is a blocklist.** Anything not named is permitted, so it
fails open when it is out of date. That is why it carries a long comment about
what it does not cover, and why the exit scan exists.

Every entry in `dangerous-paths.txt` names a path and how to treat it:

```
hide   dir    .githooks                   # invisible and unwritable
pin    file   .envrc                      # readable, not writable
warn   file   package.json                # untouched; reported if written
```

---

## Where to read more

Nothing in this project is documented only here. Each file explains itself, and
the explanations are where the code is.

| Read this | For |
|---|---|
| `dangerous-paths.txt` | The write-protection list, the format, the three holes a list cannot close, and which entries depend on the operating policy. Start here — it is the most important file to understand. |
| `lib/safer-common.sh` § 7 | How paths are covered, and why covering a file that exists is only half the job. |
| `lib/safer-common.sh` § 7b | The exit scan: what it looks for and how it measures. |
| `lib/safer-common.sh` § 8 | `--add` and `--rw`, and the confirmation. |
| `lib/safer-common.sh` § 9 | The config strategy essay: why a throwaway copy beats a read-only mount, and why the hook risk disappears rather than being contained. |
| `lib/safer-common.sh` § 10 | The sealed network, the gatekeeper, and the connection log. |
| `lib/safer-common.sh` § 13 | When an image rebuilds, and why the check is not version-only. |
| `docker/Dockerfile.claude` | What is in the image, and why git is purged twice and then asserted absent. |
| `docker/Dockerfile.forwarder` | Why the Ollama path needs nginx and not a byte-copying relay. |
| `proxy/allowlist-common.txt` | The rules for widening the network, including which reputable hosts are still a bad idea. |
| `proxy/ollama.conf` | Which Ollama endpoints are permitted, and which are refused. |
| `connection_logs/README.md` | How to read a log, how to decide whether to allow a host, and what the logs cannot tell you. |
| `connection_logs/*.log` | What each run tried to reach and what appeared in your project. |

---

## Known limits

These are recorded properly in the files that own them; this is the short list.

- The image has to be rebuilt when you upgrade the tool on your Mac. The command
  does it automatically, which means an upgrade makes one session start slowly.
- Settings changed inside the sandbox do not persist. That is the config
  strategy working, not a bug.
- `codex` and `opencode` session history is per-session. `codex resume` will not
  see earlier container runs. `safer-claude` keeps this project's transcript.
- A run killed with `kill -9` skips the exit trap, so the placeholder files stay
  in your project and the exit scan does not run. Delete the empty files by
  hand.
- Cloud-backed Ollama models make their outbound connection from your Mac's
  daemon, not from the container, so the gatekeeper never sees that traffic and
  the log cannot record it. `safer-opencode` names any such model at startup.

---

## A note on the operating policy

Some of this depends on a habit rather than on code, and the files say so where
it matters:

- The agents are never run natively in a real project folder. On the Mac they
  are started only in empty folders, to change settings or update hooks.
- Only code and config are mounted. Secret-bearing paths — `settings.php`,
  `.env`, `~/.ssh` — are not.
- Mounted code is treated as untrusted and is reviewed before anything runs on
  the host.

`dangerous-paths.txt` groups its entries by whether they depend on the first of
these. If the policy changes, that section tells you what becomes load-bearing
again.
