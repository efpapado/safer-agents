# sessions

One record per **running** session, named by tool, start time and process id:

    claude-2026-09-23T11-02-40.48213.session

Each command writes its record just before the container starts, and deletes it
as the last step of its cleanup. So this folder is normally empty while nothing
runs. A record that is still here after its run has ended belongs to a run that
died without cleanup: `kill -9`, a power loss, a terminal closed hard.

## What a record holds

The two things a run leaves on your Mac for the length of a session, and that
cleanup normally removes:

1. The **empty placeholders**. For every path in `../dangerous-paths.txt` that
   does not exist in a mounted folder, the run mounts an empty file or folder
   over the place where it would go, so the agent cannot create it. Docker
   needs something to mount on, so it creates that path in your project.
2. The **exclude file**, `.git/info/exclude` of the project, where the run
   wrote a block of ignore rules between two marker lines. The block hides
   the placeholders from `git status` during the session.

The file starts with comments that explain the same thing. Below them, one
fact per line: a keyword, then its value.

## How to repair

From any folder:

    safer-claude --repair

Any of the three commands does the same job. It reads every record here,
deletes each placeholder that is still empty, removes the marker block from
each exclude file, and deletes the record. A placeholder with content is kept
and reported: the agent wrote it, or you did, and it is not the launcher's to
delete.

Every launch of any command runs the same repair first, so a normal new run
also heals what an earlier one left. A record whose run is still active is
skipped, so two sessions in two projects do not disturb each other.

## Why here

The record must outlive the run, be found by a later run of a **different**
tool in a **different** project, and be out of the agent's reach. The launcher
folder is all three: it is never mounted, and `--add`, `--ro` and the working
directory check refuse it. Section 7c of `../lib/safer-common.sh` has the
details.
