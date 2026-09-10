# history

Session history that a tool cannot keep per project on its own. Today that is
Codex only:

    history/codex/<module slug>/sessions/YYYY/MM/DD/rollout-*.jsonl
    history/codex/<module slug>/archived_sessions/...

The slug is the module's full path with every character that is not a letter or
digit replaced by a dash — the same name Claude Code uses under
`~/.claude/projects`. One folder per module, created on the first run there.

Everything under this folder except this file is ignored by git. The rule lives
in the repository's `.gitignore`, which is never mounted into a container, so
the agent cannot change it.

## Why it is here and not in `~/.codex`

Codex keeps every project's sessions in one folder. Binding that folder into
the sandbox would show one module's agent the conversations of every project.
So `safer-codex` gives each module its own folder here and mounts only that
one. The others sit next to it on your Mac and never enter the container.

The launcher folder is already protected: `--add`, `--rw` and the
working-directory check refuse anything inside it. Docker mounts only the leaf
folder for the current module, so `proxy/`, `connection_logs/` and the other
modules' history stay out of reach even though they are neighbours on disk.

## What the agent can do with it

The mounted folder is read-write, so the agent can add, change and delete its
own transcripts. Treat a saved conversation as agent output, not as a record of
what happened. Do not follow symlinks inside these folders; the two commands
below never do.

Transcripts hold prompts and excerpts of the files the agent read. Mounted
content is code, not secrets, but this is still text that used to disappear at
the end of a run and now stays on disk.

## Commands

    safer-codex --history          one block per module: session count, newest day
    safer-codex --merge-history    copy every session into ~/.codex, skip existing

Both run on your Mac without a container. The merge copies; it never moves,
overwrites or deletes. Run it whenever you want an overview in your native
Codex, then list them there with `codex resume --all` from an empty folder.
Without `--all` the picker shows only sessions recorded in the folder you are
in, and the native tool is never started inside a module.

To forget one module's history, delete its folder:

    rm -r history/codex/<module slug>

## Moving to a new Mac

Copy the launcher folder, history included. The slug holds the absolute module
path, so if the module lives at a different path on the new machine, rename the
folder to the new slug. Nothing inside the files depends on the folder name.

## What is not kept

Only the two session folders persist. `config.toml`, `hooks.json`, the prompt
history file `history.jsonl`, logs and Codex's SQLite index stay in the
throwaway copy. Codex rebuilds the index from the session files at start, so
with many saved sessions the first `codex resume` of a run can take a moment.
