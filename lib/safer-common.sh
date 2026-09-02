# =============================================================================
#  lib/safer-common.sh — the sandbox machinery, shared by all three commands
# =============================================================================
#
#  WHAT THIS FILE IS
#  There are three commands next to this folder: safer-claude, safer-codex and
#  safer-opencode. Each one knows about its own tool: where that tool keeps its
#  settings, which files of its own can run code on your Mac, which flags it
#  accepts, which image it runs.
#
#  Everything else is the same for all three — the sealed network, the
#  gatekeeper, hiding .git directories, covering the paths in
#  dangerous-paths.txt, checking mount paths, writing the connection log. That
#  is what lives here.
#
#  WHY SHARED RATHER THAN COPIED
#  This is the security-critical half. A mistake in here is a hole in the
#  sandbox. Three copies of it would mean fixing every such mistake three times
#  and eventually missing one. One copy means a fix lands in all three commands
#  at once.
#
#  HOW A COMMAND USES IT
#  The command sets TOOL, sources this file, then fills in the rest:
#
#      TOOL="claude"
#      source "$SAFER_ROOT/lib/safer-common.sh"
#
#      IMAGE="agent-claude"
#      DOCKERFILE="$DOCKER_DIR/Dockerfile.claude"
#      VERSION_COMMAND=(claude --version)
#      DEFAULT_COMMAND=(claude)
#      PROTECTED_ROOTS+=("$HOME/.claude")
#      ... read the command line ...
#
#      safer_check_workdir
#      safer_ensure_agent_image
#      build_config            # the command's own function
#      apply_config_copies
#      safer_protect_paths
#      safer_setup_network
#      safer_run
#
#  ---------------------------------------------------------------------------
#  WHAT THIS PROTECTS AGAINST
#  ---------------------------------------------------------------------------
#  Three things, and they are different:
#
#  (a) The agent running code on your Mac *now*. Handled by the container
#      itself: no privileges, non-root, read-only image.
#
#  (b) The agent writing something that makes code run on your Mac *later* — a
#      git hook, an editor task file, a .envrc, a settings file with a hook in
#      it. Handled in three places: .git is hidden everywhere, the paths in
#      dangerous-paths.txt are covered in every mounted folder (both in
#      section 7), and the tool's own config is a throwaway copy rather than a
#      mount (section 9).
#
#      Section 7 is a blocklist, so it cannot be complete. Section 7b accepts
#      that and reports, at exit, every auto-run candidate that appeared during
#      the session. It blocks nothing. Read dangerous-paths.txt for what the
#      list cannot cover and why.
#
#      Extra folders given with --add are mounted READ-ONLY. Only the project
#      folder, and anything given with --rw, can be written at all. --rw on a
#      folder outside the project asks you to confirm it first; see section 8.
#
#  (c) The agent sending data out, or fetching instructions in. Handled by the
#      network section: the container is put on a sealed network and may only
#      reach the hosts on its allowlist.
#
#  ---------------------------------------------------------------------------
#  FOLDER LAYOUT
#  ---------------------------------------------------------------------------
#      safer-claude                 the three commands
#      safer-codex
#      safer-opencode
#      lib/safer-common.sh          this file
#
#      dangerous-paths.txt          paths the agent may not write   <- edit this
#
#      docker/Dockerfile.claude     one agent image per tool
#      docker/Dockerfile.codex
#      docker/Dockerfile.opencode
#      docker/Dockerfile.proxy      the gatekeeper's image  (shared)
#      docker/Dockerfile.forwarder  the Ollama forwarder    (opencode only)
#
#      docker/ is also the BUILD CONTEXT for every one of them. See the note
#      at DOCKER_DIR below.
#
#      proxy/tinyproxy.conf         gatekeeper settings     (shared)
#      proxy/ollama.conf            forwarder rules         (opencode only)
#      proxy/allowlist-common.txt   destinations for ALL tools  <- edit this
#      proxy/allowlist-claude.txt   destinations for one tool   <- and these
#      proxy/allowlist-codex.txt
#      proxy/allowlist-opencode.txt
#
#      connection_logs/             one file per run, named claude-<time>.log
#
#  ---------------------------------------------------------------------------
#  A FEW BASH NOTES, since these files are meant to be readable
#  ---------------------------------------------------------------------------
#  set -e            stop the whole script the moment any command fails.
#                    Without it, a failed `mkdir` would be ignored and the
#                    script would carry on into a broken state.
#  set -u            treat the use of an undefined variable as an error. Catches
#                    typos that would otherwise silently expand to nothing —
#                    which in a script full of paths could mean `rm -rf /`.
#  set -o pipefail   in `a | b`, fail if EITHER command fails. By default only
#                    the last one counts.
#
#  ARRAY=( ... )                  a list.
#  "${ARRAY[@]}"                  every element, each kept as one word even if
#                                 it contains spaces. The quotes matter.
#  ${ARRAY+"${ARRAY[@]}"}         the same, but expands to nothing when the
#                                 array is empty. Needed because `set -u` treats
#                                 an empty array as undefined in older Bash,
#                                 which is what macOS ships.
#  local x                        a variable that exists only inside one
#                                 function.
#  cmd >/dev/null 2>&1            throw away normal output (>) and error output
#                                 (2>). Used where we only care whether a
#                                 command succeeded.
#  cmd || true                    ignore failure. Used in cleanup, where a
#                                 failed tidy-up should not mask the real error.
# =============================================================================


# ---------------------------------------------------------------------------
#  Refuse to be run directly.
#
#  This file only makes sense when sourced by one of the commands. Run on its
#  own it would define functions and then exit, which looks like success and is
#  not.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, not a command." >&2
    echo "Run safer-claude, safer-codex or safer-opencode instead." >&2
    exit 1
fi

if [[ -z "${TOOL:-}" ]]; then
    echo "Internal error: TOOL must be set before sourcing safer-common.sh" >&2
    exit 1
fi

if [[ -z "${SAFER_ROOT:-}" ]]; then
    echo "Internal error: SAFER_ROOT must be set before sourcing safer-common.sh" >&2
    exit 1
fi


# =============================================================================
#  SECTION 1 — Paths and settings
# =============================================================================

LOG_DIR="$SAFER_ROOT/connection_logs"
PROXY_DIR="$SAFER_ROOT/proxy"
PROXY_CONF="$PROXY_DIR/tinyproxy.conf"

# ---------------------------------------------------------------------------
#  The allowlists. Two files are read and joined:
#
#    allowlist-common.txt   destinations you want from every tool — the PHP
#                           manual, drupal.org, and so on
#    allowlist-<tool>.txt   destinations only this tool needs, which is mostly
#                           its own model API and its own login service
#
#  Splitting them this way means claude cannot reach OpenAI's servers and codex
#  cannot reach Anthropic's. Nothing depends on that, but a narrower list is a
#  better list, and an unexpected entry in a connection log is easier to notice.
# ---------------------------------------------------------------------------
ALLOWLIST_COMMON="$PROXY_DIR/allowlist-common.txt"
ALLOWLIST_TOOL="$PROXY_DIR/allowlist-$TOOL.txt"

# ---------------------------------------------------------------------------
#  The list of paths inside a code tree that must not be writable — git hook
#  folders, .envrc, editor task files, project-level agent settings. Read at
#  launch and applied to every mounted folder. Shared by all three commands;
#  the file itself explains the format and the two ways it can be defeated.
# ---------------------------------------------------------------------------
DANGEROUS_PATHS="$SAFER_ROOT/dangerous-paths.txt"

# ---------------------------------------------------------------------------
#  Where the image recipes live.
#
#  One constant rather than five literal paths. Each command names its own file
#  relative to this, so moving the folder again is one edit.
#
#  THIS IS ALSO THE BUILD CONTEXT, and that is deliberate. The context is the
#  set of files Docker sends to its daemon before a build starts. Keep it at
#  this folder and not at $SAFER_ROOT: a wider context ships the launcher, the
#  library, the allowlists and connection_logs/ to the daemon in order to build
#  an image that reads none of them. None of these Dockerfiles has a COPY or an
#  ADD, so the context can be the folder holding them and nothing is lost.
#
#  If a Dockerfile ever gains a COPY, the file it copies must be inside this
#  folder. That is a feature: it keeps the answer to "what can a build read"
#  down to one directory.
# ---------------------------------------------------------------------------
DOCKER_DIR="$SAFER_ROOT/docker"


# ---------------------------------------------------------------------------
#  Settings you may want to change
# ---------------------------------------------------------------------------

# Name of the gatekeeper image, built from docker/Dockerfile.proxy. Shared by all
# three commands: it contains no tool-specific anything.
PROXY_IMAGE="safer-gatekeeper"

# Port the gatekeeper listens on, inside the Docker network only. Never exposed
# to your Mac or to anything else.
PROXY_PORT=8888

# ---------------------------------------------------------------------------
#  Address ranges for the sealed network.
#
#  Each run needs its own range, otherwise a second run cannot create its
#  network and fails with a confusing Docker error. So there is a pool, and
#  start_network tries them in order until one is free. Sixteen is enough for
#  any plausible number of sessions at once — and it means you can run
#  safer-claude on one project and safer-opencode on another at the same time.
#
#  All sixteen sit inside 172.31.240.0/20, which is what the single `Allow`
#  line in proxy/tinyproxy.conf names. That line is what stops OTHER containers
#  from borrowing the gatekeeper: the gatekeeper is attached to a normal Docker
#  network too, since that is how it reaches the internet, so its neighbours
#  there could otherwise use it.
#
#  If this whole block collides with something on your machine, change it here
#  AND change the Allow line in proxy/tinyproxy.conf to match.
# ---------------------------------------------------------------------------
SUBNET_POOL=(
    172.31.240.0/24 172.31.241.0/24 172.31.242.0/24 172.31.243.0/24
    172.31.244.0/24 172.31.245.0/24 172.31.246.0/24 172.31.247.0/24
    172.31.248.0/24 172.31.249.0/24 172.31.250.0/24 172.31.251.0/24
    172.31.252.0/24 172.31.253.0/24 172.31.254.0/24 172.31.255.0/24
)

# How many run logs to keep per tool before deleting the oldest. Counted per
# tool, so a busy week of claude does not delete your codex logs.
LOG_KEEP=30

# Names the agent may contact WITHOUT going through the gatekeeper. A command
# may append to this: safer-opencode adds the Ollama forwarder.
NO_PROXY_HOSTS="localhost,127.0.0.1"


# =============================================================================
#  SECTION 2 — State
#
#  Bash has no real data structures, so the pattern throughout is "parallel
#  arrays": several lists that are read together by index. For example
#  COPY_SRCS[0] and COPY_DSTS[0] together describe one file to copy in.
# =============================================================================

EXTRA_MOUNTS=()        # --mount arguments for --add / --ro / --rw folders
MOUNT_ROOTS=()         # the host paths of those folders, for the path scans
RW_MOUNTS=()           # just the ones given with --rw, for the run log
GIT_MASKS=()           # --mount arguments that hide .git directories
GIT_MASKS_SEEN=$'\n'   # a newline-delimited string used as a crude "set", to
                       # avoid masking the same .git twice
PATH_PINS=()           # --mount arguments from dangerous-paths.txt
PATH_PINS_SEEN=$'\n'   # the same crude "set", for those
PREEMPTED_PATHS=()     # host paths that did NOT exist when we covered them.
                       # Docker creates each one on your Mac to have something
                       # to mount on. Cleanup deletes them again. See the
                       # "residue" note in section 7.
PREEMPTED_FILES=()     # the subset of PREEMPTED_PATHS that are FILES. Only
                       # these are visible to git — `git status` does not
                       # report an empty folder — so only these are hidden
                       # from it. See hide_placeholders_from_git in section 7.
EXCLUDE_FILE=""        # the project's .git/info/exclude, once resolved.
                       # Empty when the project is not a git repository.
CONFIG_SCAN_HOSTS=()   # config items bound back from your Mac: the host path
CONFIG_SCAN_CONTS=()   # ...and where each appears in the container
SCAN_ROOTS=()          # the writable trees the exit scan looks at
SCAN_BASELINE=""       # what those trees held at launch. See section 7b.
SCAN_MARKER=""         # a file stamped at launch, so `find -newer` can say
                       # what was written while the agent was running
EMPTY_FILE=""          # a shared empty file used to shadow .git *files*
SCRATCH_DIR=""         # temporary working folder, deleted on exit
AUTH_MOUNTS=()         # the mount for the throwaway config folder itself
CONFIG_MOUNTS=()       # mounts bound back into that folder
COPY_SRCS=()           # config files handed in as a throwaway copy
COPY_DSTS=()
CONFIG_DSTS=()         # container paths of the throwaway config FOLDERS

# Where $HOME is inside the container. One constant, because the tmpfs mounts
# and the --env HOME in section 14 must agree.
CONTAINER_HOME="/home/agent"

HOME_MOUNTS=()         # the tmpfs mounts that make $HOME writable
IDENTITY_MOUNTS=()     # /etc/passwd and /etc/group, so the user id has a name
HOME_DIRS_SEEN=$'\n'   # the crude "set" of folders already covered
PROTECTED_ROOTS=()     # paths that --add and --ro must refuse
TOOL_ARGS=()           # loose arguments passed through to the agent
COMMAND_ARGS=()        # a command given after --
TOOL_ENV=()            # --env arguments specific to the chosen tool
EXTRA_ALLOW=()         # hostnames added with --allow

OFFLINE=0              # 1 when --offline was given
HOST_PATH=""           # the project folder, set by safer_check_workdir
CONTAINER_PATH=""

# Network state. Set once the network and gatekeeper exist, so that cleanup
# knows what to tear down.
NET_NAME=""
PROXY_NAME=""
NET_CREATED=0
PROXY_STARTED=0
NET_ARGS=()
EFFECTIVE_ALLOWLIST=""
RUN_LOG=""

# Set by safer-opencode's forwarder. Named here so cleanup and the log writer
# can refer to it unconditionally.
OLLAMA_NAME=""
EFFECTIVE_OLLAMA_CONF=""

# How many arguments parse_common_arg consumed. See section 11.
ARGS_CONSUMED=0


# =============================================================================
#  SECTION 3 — Cleanup
#
#  `trap cleanup EXIT` registers a function that Bash runs when the script ends
#  for ANY reason: normal finish, an error under `set -e`, or Ctrl-C. This is
#  the only reliable way to guarantee that the network and the gatekeeper
#  container do not survive the session.
#
#  Every command here ends in `|| true`. A failure while tidying up must not
#  replace the real error message with a confusing one, and must not stop the
#  remaining tidy-up steps from running.
# =============================================================================

cleanup() {
    # --- 1. Save the gatekeeper's log BEFORE destroying the container -------
    #
    #     Order matters. `docker logs` reads from the container, so once the
    #     container is removed the log is gone with it.
    if [[ "$PROXY_STARTED" -eq 1 ]]; then
        save_connection_log || true
    fi

    # --- 2. Remove the gatekeeper -----------------------------------------
    #
    #     -f forces it: stop the process and delete the container in one step.
    if [[ -n "$PROXY_NAME" ]]; then
        docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
    fi

    # --- 2b. Remove the Ollama forwarder, if this command started one ------
    if [[ -n "$OLLAMA_NAME" ]]; then
        docker rm -f "$OLLAMA_NAME" >/dev/null 2>&1 || true
    fi

    # --- 3. Remove the sealed network -------------------------------------
    #
    #     This only succeeds once no containers are attached, which is why it
    #     comes after step 2.
    if [[ "$NET_CREATED" -eq 1 && -n "$NET_NAME" ]]; then
        docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    fi

    # --- 4. Remove the generated config files -----------------------------
    if [[ -n "$EFFECTIVE_ALLOWLIST" && -f "$EFFECTIVE_ALLOWLIST" ]]; then
        rm -f "$EFFECTIVE_ALLOWLIST" || true
    fi
    if [[ -n "$EFFECTIVE_OLLAMA_CONF" && -f "$EFFECTIVE_OLLAMA_CONF" ]]; then
        rm -f "$EFFECTIVE_OLLAMA_CONF" || true
    fi

    # --- 5. Remove the empty placeholders left in your project -------------
    remove_preempted_residue || true

    #     ...and make the paths visible to git again. AFTER the removal, on
    #     purpose: a placeholder that was not empty is left in place, and from
    #     this moment it must show in `git status`.
    remove_exclude_block || true

    # --- 5b. Report auto-run files that appeared during the session --------
    #
    #     AFTER step 5, deliberately. Step 5 deletes the empty placeholders
    #     this run created. Scanning before it would report every one of them
    #     as a new dangerous file, which is the opposite of useful.
    report_new_dangerous_paths || true

    # --- 6. Remove temporary files ----------------------------------------
    if [[ -n "$SCRATCH_DIR" ]]; then
        rm -rf "$SCRATCH_DIR" || true
    fi
}

# ---------------------------------------------------------------------------
#  Delete the empty files and folders Docker created as mount points.
#
#  Section 7 pre-empts a dangerous path that is absent: it mounts a placeholder
#  where the file or folder would go. Docker creates that destination, and the
#  destination is in a folder bound from your Mac. So the run leaves an empty
#  .envrc, .gitlab-ci.yml, .mcp.json and similar in your project, and git shows
#  them as new files.
#
#  This removes them again. Two rules keep it safe:
#
#    * Only paths recorded in PREEMPTED_PATHS. Each one was absent at launch,
#      so nothing of yours can be here.
#    * Only if it is still empty. A file must be 0 bytes, and `rmdir` refuses a
#      folder with anything in it. Content means someone wrote it after the
#      mounts were released, and it is not ours to delete.
#
#  Each recorded path is the topmost missing component of its entry, so one
#  recorded path never sits inside another. Order does not matter.
#
#  A run that dies without the exit trap — a power loss, `kill -9` — still
#  leaves the placeholders behind. Delete those by hand.
# ---------------------------------------------------------------------------
remove_preempted_residue() {
    local path

    for path in ${PREEMPTED_PATHS+"${PREEMPTED_PATHS[@]}"}; do
        # A symlink here is not something we made. Leave it alone.
        if [[ -L "$path" ]]; then
            continue
        fi
        if [[ -d "$path" ]]; then
            rmdir "$path" 2>/dev/null || true
        elif [[ -f "$path" && ! -s "$path" ]]; then
            rm -f "$path" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT


# =============================================================================
#  SECTION 4 — Small helpers
# =============================================================================

# ---------------------------------------------------------------------------
#  Docker's --mount option takes comma-separated key=value pairs:
#
#      --mount type=bind,src=/a/b,dst=/a/b,readonly
#
#  So a comma inside a path would be read as the start of a new option, and the
#  error message Docker produces is unhelpful. Refuse early instead.
# ---------------------------------------------------------------------------
check_mount_path() {
    if [[ "$1" == *,* ]]; then
        echo "Error: mount paths cannot contain a comma: $1" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
#  Create a temporary folder for this run.
#
#  Why under $HOME and not in the system temp folder: Docker Desktop on macOS
#  runs containers inside a hidden Linux virtual machine, and only some folders
#  are shared into it. The system temp folder (/var/folders/...) is not reliably
#  shared, and its path ends in a slash, which produces a doubled slash that
#  Docker rejects with "bind source path does not exist". $HOME is shared,
#  because that is where the tool config is mounted from.
# ---------------------------------------------------------------------------
init_scratch() {
    local base="$HOME/.cache/safer-agent"

    # Already created for this run? Nothing to do.
    if [[ -n "$SCRATCH_DIR" ]]; then
        return 0
    fi

    mkdir -p "$base"
    chmod 0700 "$base"          # only you may read it

    # Clear folders left behind by a run that was killed so hard the exit trap
    # never ran (a power loss, `kill -9`).
    find "$base" -maxdepth 1 -name 'run.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true

    # mktemp -d creates a folder with a random name, so two runs never collide.
    SCRATCH_DIR="$(mktemp -d "$base/run.XXXXXX")"
    check_mount_path "$SCRATCH_DIR"
}

# ---------------------------------------------------------------------------
#  Declare a config file handed to the container as a throwaway copy.
#
#  Used for files that live OUTSIDE the tool's config folder, so the helpers in
#  section 9 do not cover them. Currently only ~/.claude.json.
# ---------------------------------------------------------------------------
add_copy() {
    COPY_SRCS+=("$1")
    COPY_DSTS+=("$2")
}


# =============================================================================
#  SECTION 5 — Protected paths
# =============================================================================

# ---------------------------------------------------------------------------
#  This folder holds the allowlists and the logs. If the agent could write to
#  either, it could grant itself destinations or erase the record of what it
#  tried. So treat it like the tool config: refuse to mount it.
#
#  Each command adds its own config folders to this list after sourcing.
# ---------------------------------------------------------------------------
PROTECTED_ROOTS+=("$SAFER_ROOT")


# =============================================================================
#  SECTION 6 — Path safety checks used by --add and --ro
# =============================================================================

# ---------------------------------------------------------------------------
#  Refuse anything git-related.
#
#  Git is out of scope for the agent, so it must not be mountable on request
#  either. .git holds hooks and config that execute on your Mac later, and the
#  other .git* files feed git commands you run yourself.
# ---------------------------------------------------------------------------
reject_git_path() {
    local raw="$1"        # what the user typed
    local resolved="$2"   # the full path it points at

    # `case` with shell patterns: */.git matches a path ending in /.git,
    # */.git/* matches anything inside one.
    case "$resolved" in
        */.git|*/.git/*)
            echo "Error: refusing to mount a git path: $raw" >&2
            echo "Git is disabled inside the sandbox; handle version control on the host." >&2
            exit 1
            ;;
    esac

    # Also catch .gitignore, .gitmodules, .gitconfig and friends.
    case "$(basename "$resolved")" in
        .git*)
            echo "Error: refusing to mount a git-related path: $raw" >&2
            echo "Git is disabled inside the sandbox; handle version control on the host." >&2
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
#  Refuse anything overlapping a protected folder.
#
#  The tool config is already handled, with its dangerous parts either copied
#  or pinned read-only. Mounting any of it a SECOND time somewhere else would
#  hand back write access at a path those measures do not cover.
#
#  Both directions are checked:
#      resolved inside root   -->  --add ~/.claude/hooks
#      root inside resolved   -->  --add ~        (which contains ~/.claude)
#
#  The second check is why `--add ~` and `--add /` are refused.
# ---------------------------------------------------------------------------
reject_config_path() {
    local raw="$1"
    local resolved="$2"
    local root

    for root in ${PROTECTED_ROOTS+"${PROTECTED_ROOTS[@]}"}; do
        if [[ "$resolved" == "$root" || "$resolved" == "$root"/* || "$root" == "$resolved"/* ]]; then
            echo "Error: refusing to mount '$raw': it overlaps a protected path at $root" >&2
            echo "Protected paths are the $TOOL config and this script's own folder." >&2
            exit 1
        fi
    done
}


# =============================================================================
#  SECTION 7 — Covering paths that must not be writable
#
#  Two jobs, one mechanism.
#
#  (1) .git directories. Git is out of scope inside the container, and .git
#      holds hooks and config that run on your Mac later.
#
#  (2) The paths listed in dangerous-paths.txt: .githooks, .envrc, .vscode,
#      .devcontainer, project-level agent settings, CI definitions. Same
#      problem, different names.
#
#  THE TRICK THAT MAKES BOTH WORK
#  Docker sorts mounts by how deep their destination is and applies the shallow
#  ones first. So a mount at /project/.envrc ALWAYS lands on top of a mount at
#  /project, whatever order they appear in on the command line. That is what
#  lets a read-write project folder contain read-only islands.
#
#  THE PART THAT IS EASY TO GET WRONG
#  Covering a file that exists does nothing about the agent CREATING that file.
#  An .envrc written into a project that never had one is exactly the attack
#  the list is meant to stop. So every entry is applied in two ways: existing
#  occurrences at any depth are covered, AND a placeholder is mounted at the
#  top of the tree when the path is absent. See dangerous-paths.txt for what
#  still gets through.
# =============================================================================

# ---------------------------------------------------------------------------
#  A shared empty read-only file, created on first use.
#
#  Used to shadow paths that are FILES. A tmpfs cannot cover a file — it is a
#  filesystem, and a filesystem needs a directory to be mounted on — so a file
#  needs a file. One empty file serves every such mount.
# ---------------------------------------------------------------------------
#  It sets the global EMPTY_FILE rather than printing the path. That is not a
#  style choice. Called as $(empty_file), it would run in a subshell, and the
#  assignments to EMPTY_FILE and SCRATCH_DIR would be thrown away when the
#  subshell exited — so every caller would create a NEW scratch folder, and the
#  exit trap would only know about the last one. The rest would be left behind.
ensure_empty_file() {
    if [[ -n "$EMPTY_FILE" ]]; then
        return 0
    fi
    init_scratch
    EMPTY_FILE="$SCRATCH_DIR/empty"
    : > "$EMPTY_FILE"              # `:` is "do nothing"; the > creates the file
    chmod 0444 "$EMPTY_FILE"
}

# ---------------------------------------------------------------------------
#  An empty unwritable DIRECTORY at one container path.
#
#  tmpfs = a filesystem that lives in memory and disappears with the container.
#  Mounted over a folder it simply covers whatever was there.
#
#  tmpfs-mode=0555 makes it read-only for everyone. The agent has no
#  capabilities and is not root, so it can neither write into it nor unmount
#  it. tmpfs-size is tiny because nothing is ever meant to go in.
# ---------------------------------------------------------------------------
tmpfs_mount_arg() {
    printf 'type=tmpfs,dst=%s,tmpfs-size=65536,tmpfs-mode=0555' "$1"
}


# ---------------------------------------------------------------------------
#  Hide one .git path.
#
#  $1  where it is on your Mac, so we can look at what it actually is
#  $2  where it appears in the container, which is what gets mounted over
#
#  The two differ for config folders: ~/.claude/plugins on your Mac appears at
#  /home/agent/.claude/plugins in the container. For a project folder they are
#  the same path.
# ---------------------------------------------------------------------------
add_git_mask() {
    local host="$1"
    local cont="$2"

    # Have we already masked this one? GIT_MASKS_SEEN is a long string of
    # newline-delimited paths, searched with a shell pattern.
    case "$GIT_MASKS_SEEN" in
        *$'\n'"$cont"$'\n'*) return 0 ;;
    esac
    GIT_MASKS_SEEN="$GIT_MASKS_SEEN$cont"$'\n'

    check_mount_path "$cont"

    # A .git that is a symlink cannot be hidden safely: we would be masking the
    # link, not what it points at, and resolving it could lead anywhere. Stop
    # and let a human decide.
    if [[ -L "$host" ]]; then
        echo "Error: '$host' is a symlink named .git" >&2
        echo "It cannot be masked safely — resolve or remove it before launching." >&2
        exit 1
    fi

    if [[ -d "$host" ]]; then
        GIT_MASKS+=(--mount "$(tmpfs_mount_arg "$cont")")
        return 0
    fi

    # A .git that is a FILE, not a folder, is a pointer used by submodules and
    # worktrees. Shadow it with a read-only empty file instead.
    ensure_empty_file
    GIT_MASKS+=(--mount "type=bind,src=$EMPTY_FILE,dst=$cont,readonly")
}

# ---------------------------------------------------------------------------
#  Find and hide every .git under one folder, however deep — nested modules,
#  vendored libraries, and so on.
#
#  $1  the folder on your Mac       $2  where that folder appears in the
#                                       container (omit when they are equal)
#
#  -prune stops find from descending INTO a .git once it has found it. There is
#  nothing in there we need, and skipping it is much faster.
#
#  The `while read` / `done < <(...)` shape is called process substitution. It
#  runs `find` and feeds its output line by line into the loop. The obvious
#  alternative, `find ... | while read`, would run the loop in a subshell,
#  where the changes it makes to GIT_MASKS would be thrown away.
# ---------------------------------------------------------------------------
mask_git_in_tree() {
    local host_root="$1"
    local cont_root="${2:-$1}"
    local path

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        # Translate the host path to its container equivalent by swapping the
        # root prefix. ${path#"$host_root"} strips that prefix.
        add_git_mask "$path" "$cont_root${path#"$host_root"}"
    done < <(find "$host_root" -name '.git' -prune -print 2>/dev/null)
}


# ---------------------------------------------------------------------------
#  Cover one dangerous path.
#
#  $1  action: "hide" (an empty placeholder) or "pin" (the real thing,
#      read-only)
#  $2  type:   "dir" or "file" — only consulted when the path is absent, since
#              that is the case where there is nothing to look at
#  $3  where it is on your Mac
#  $4  where it appears in the container
# ---------------------------------------------------------------------------
add_path_pin() {
    local action="$1"
    local type="$2"
    local host="$3"
    local cont="$4"

    case "$PATH_PINS_SEEN" in
        *$'\n'"$cont"$'\n'*) return 0 ;;
    esac

    # Never cover a path that is itself a mount root. Two mounts with the same
    # destination is a Docker error, and it would be a confusing one. This
    # happens if someone writes --rw ~/projects/foo/.vscode.
    local root
    for root in ${MOUNT_ROOTS+"${MOUNT_ROOTS[@]}"}; do
        if [[ "$host" == "$root" ]]; then
            # Recorded as decided, so the warning is printed once rather than
            # again for every tree the path turns up in.
            PATH_PINS_SEEN="$PATH_PINS_SEEN$cont"$'\n'
            echo "Warning: $host is listed in $(basename "$DANGEROUS_PATHS")" >&2
            echo "         but was also mounted explicitly. Leaving it as mounted." >&2
            return 0
        fi
    done

    PATH_PINS_SEEN="$PATH_PINS_SEEN$cont"$'\n'
    check_mount_path "$cont"

    # A symlink is refused for the same reason a symlinked .git is: we would be
    # covering the link and not what it points at.
    if [[ -L "$host" ]]; then
        echo "Error: '$host' is a symlink, and $(basename "$DANGEROUS_PATHS") lists it" >&2
        echo "as a path that must not be writable. Resolve or remove it before launching." >&2
        exit 1
    fi

    # It exists, and we are allowed to show it: bind the real thing read-only.
    if [[ "$action" == "pin" && -e "$host" ]]; then
        check_mount_path "$host"
        PATH_PINS+=(--mount "type=bind,src=$host,dst=$cont,readonly")
        return 0
    fi

    # Everything else gets an empty unwritable placeholder: either because we
    # are hiding real contents, or because there are no contents and we are
    # making sure none can be created.
    #
    #  A placeholder for an ABSENT path has a cost. Docker must have something
    #  to mount on, so it creates the destination. The destination is inside a
    #  folder bound from your Mac, so the empty file or folder appears in your
    #  project, and `git status` reports it. Record it here; cleanup deletes it
    #  after the session, but only while it is still empty.
    if [[ ! -e "$host" ]]; then
        PREEMPTED_PATHS+=("$host")
        # The FILE placeholders are also hidden from `git status` while the
        # session runs — see hide_placeholders_from_git. Folders are not
        # recorded for that: git never reports an empty folder, and a rule
        # that hides nothing today could hide something after a crash.
        if [[ "$type" != "dir" ]]; then
            PREEMPTED_FILES+=("$host")
        fi
    fi

    if [[ -d "$host" || ( ! -e "$host" && "$type" == "dir" ) ]]; then
        PATH_PINS+=(--mount "$(tmpfs_mount_arg "$cont")")
    else
        ensure_empty_file
        PATH_PINS+=(--mount "type=bind,src=$EMPTY_FILE,dst=$cont,readonly")
    fi
}

# ---------------------------------------------------------------------------
#  Read dangerous-paths.txt into three parallel arrays, and build the `find`
#  expression that matches all of it at once.
#
#  Read ONCE per run, not once per mounted folder. The single find expression
#  matters more than it looks: a Drupal tree with vendor/ is a lot of files,
#  and one traversal that tests fifteen patterns is far cheaper than fifteen
#  traversals that each test one.
# ---------------------------------------------------------------------------
PIN_ACTIONS=()
PIN_TYPES=()
PIN_ENTRIES=()
PIN_FIND_EXPR=()
WARN_FIND_EXPR=()      # just the `warn` entries. Section 7b uses this one.

load_dangerous_paths() {
    local action type entry

    if [[ ! -f "$DANGEROUS_PATHS" ]]; then
        echo "Error: $DANGEROUS_PATHS is missing." >&2
        echo "It lists the paths the agent must not be able to write." >&2
        echo "Refusing to run without it." >&2
        exit 1
    fi

    while read -r action type entry; do
        # Skip blank lines, comments, and anything with a missing column.
        [[ -n "${entry:-}" ]] || continue
        case "$action" in ''|'#'*) continue ;; esac

        case "$action" in
            hide|pin|warn) ;;
            *)  echo "Error: $DANGEROUS_PATHS: unknown action '$action'" >&2
                echo "Use 'hide', 'pin' or 'warn'." >&2
                exit 1 ;;
        esac
        case "$type" in
            dir|file|glob|nested) ;;
            *)  echo "Error: $DANGEROUS_PATHS: unknown type '$type' for '$entry'" >&2
                echo "Use 'dir', 'file', 'glob' or 'nested'." >&2
                exit 1 ;;
        esac
        # An absolute path would escape the tree it is applied to.
        case "$entry" in
            /*) echo "Error: $DANGEROUS_PATHS: '$entry' must be relative" >&2
                exit 1 ;;
        esac

        PIN_ACTIONS+=("$action")
        PIN_TYPES+=("$type")
        PIN_ENTRIES+=("$entry")

        # Build one big "( -path A -o -name B -o ... )" expression. The first
        # branch has no -o in front of it.
        if [[ ${#PIN_FIND_EXPR[@]} -gt 0 ]]; then
            PIN_FIND_EXPR+=(-o)
        fi
        if [[ "$type" == "glob" ]]; then
            PIN_FIND_EXPR+=(-name "$entry")
        else
            # "*/entry" matches the top of the tree as well as anything nested,
            # because * also matches the root path itself.
            PIN_FIND_EXPR+=(-path "*/$entry")
        fi

        # `warn` entries also go in a list of their own. Section 7b scans that
        # one for CHANGES, not just for new paths, which is the whole point of
        # the action: package.json already exists, so its appearance proves
        # nothing and its modification time proves everything.
        if [[ "$action" == "warn" ]]; then
            if [[ ${#WARN_FIND_EXPR[@]} -gt 0 ]]; then
                WARN_FIND_EXPR+=(-o)
            fi
            if [[ "$type" == "glob" ]]; then
                WARN_FIND_EXPR+=(-name "$entry")
            else
                WARN_FIND_EXPR+=(-path "*/$entry")
            fi
        fi
    done < "$DANGEROUS_PATHS"

    if [[ ${#PIN_ENTRIES[@]} -eq 0 ]]; then
        echo "Warning: $DANGEROUS_PATHS has no entries." >&2
        echo "         Nothing inside the mounted folders will be protected." >&2
    fi
}

# ---------------------------------------------------------------------------
#  Apply every entry to one mounted tree.
#
#  $1  the folder    $2  1 if the agent can write in it, 0 if it is read-only
#
#  Two passes, and the second one depends on $2:
#
#    1. One traversal covers every existing occurrence, at any depth. A
#       .devcontainer inside a contrib module is covered as well as one at the
#       top. In a READ-ONLY tree only "hide" entries are covered — a "pin" on
#       something that is already read-only would be a mount that changes
#       nothing.
#
#    2. If an entry is absent from the TOP of the tree, mount a placeholder
#       there anyway, so it cannot be created during the session. Only for
#       WRITABLE trees: in a read-only one there is nothing to pre-empt.
#
#       Skipped for glob entries as well: a name nobody knows cannot be
#       prepared for. See dangerous-paths.txt.
# ---------------------------------------------------------------------------
pin_dangerous_paths_in_tree() {
    local root="$1"
    local writable="$2"
    local path i matched target

    # Pass 1 — one find, then decide which entry each hit belongs to.
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue

        matched=0
        i=0
        while [[ $i -lt ${#PIN_ENTRIES[@]} ]]; do
            # ${PIN_ENTRIES[$i]} is used unquoted on the right of == on purpose:
            # that is what makes a glob entry match as a pattern.
            if [[ "$path" == */${PIN_ENTRIES[$i]} ]]; then
                # `warn` mounts nothing, ever. It is a name to watch, not a
                # name to cover. Claiming the match here is what stops the
                # "should not happen" fallback below from covering it anyway.
                if [[ "${PIN_ACTIONS[$i]}" != "warn" ]]; then
                    if [[ "$writable" -eq 1 || "${PIN_ACTIONS[$i]}" == "hide" ]]; then
                        add_path_pin "${PIN_ACTIONS[$i]}" "${PIN_TYPES[$i]}" "$path" "$path"
                    fi
                fi
                matched=1
                break
            fi
            i=$((i + 1))
        done

        # Should not happen: find matched something no entry claims. Cover it
        # anyway rather than silently letting it through.
        if [[ $matched -eq 0 && "$writable" -eq 1 ]]; then
            add_path_pin pin file "$path" "$path"
        fi
    done < <(find "$root" \( ${PIN_FIND_EXPR+"${PIN_FIND_EXPR[@]}"} \) \
                  -prune -print 2>/dev/null)

    # Pass 2 — pre-empt what is not there yet. Writable trees only.
    if [[ "$writable" -ne 1 ]]; then
        return 0
    fi

    i=0
    while [[ $i -lt ${#PIN_ENTRIES[@]} ]]; do
        if [[ "${PIN_ACTIONS[$i]}" == "warn" \
              || "${PIN_TYPES[$i]}" == "glob" \
              || -e "$root/${PIN_ENTRIES[$i]}" ]]; then
            i=$((i + 1))
            continue
        fi

        # A "nested" entry lives inside a folder its own tool writes, so that
        # folder must stay writable and must never be covered. If the parent is
        # not there, pre-empt nothing and move on.
        #
        # This is the one case where covering the topmost missing component is
        # wrong rather than merely broad. Doing it here is what stopped opencode
        # from creating <project>/.opencode/.gitignore, which is the tool's own
        # housekeeping and nothing to do with the agent.
        #
        # The cost is a documented residue: in a project with no .opencode at
        # all, .opencode/plugin is not pre-empted, so the agent could create it.
        # See dangerous-paths.txt.
        # KNOWN LIMIT — `nested` can only describe a FOLDER.
        #
        # The `dir` below is hardcoded, so an absent nested entry is always
        # pre-empted as a directory. Every nested entry today IS a folder
        # (.claude/hooks, .opencode/plugin), so nothing is wrong now.
        #
        # But a nested FILE cannot be expressed. Adding, say,
        #
        #     pin  nested  .claude/settings.local.json
        #
        # would make Docker create a DIRECTORY with that name in the project,
        # and the tool would then fail to read its own settings. Pass 1 is not
        # affected — add_path_pin tests the real path with -d, so an entry that
        # already exists is covered correctly either way.
        #
        # If a nested file is ever needed, add a fifth type — `nested-file` —
        # and pass `file` here for it. Do not simply add the entry.
        # This is recorded in the FORMAT section of dangerous-paths.txt too.
        if [[ "${PIN_TYPES[$i]}" == "nested" ]]; then
            if [[ -d "$(dirname "$root/${PIN_ENTRIES[$i]}")" ]]; then
                add_path_pin "${PIN_ACTIONS[$i]}" dir \
                             "$root/${PIN_ENTRIES[$i]}" "$root/${PIN_ENTRIES[$i]}"
            fi
            i=$((i + 1))
            continue
        fi

        # Any other multi-component entry, such as .github/workflows, needs its
        # parent to exist. If it does not, mounting there would make Docker
        # create the missing PARENT folder ON YOUR MAC, inside your project. So
        # cover the topmost missing component instead, as a directory. Docker
        # then creates that one component and nothing under it, and cleanup
        # deletes it again — see remove_preempted_residue in section 3.
        #
        # Nothing is lost by doing that: the folder does not exist, so it has no
        # contents to hide. And it is the stronger control — the agent cannot
        # create .github at all, rather than only .github/workflows.
        target="$root/${PIN_ENTRIES[$i]}"
        while [[ "$target" != "$root" && ! -d "$(dirname "$target")" ]]; do
            target="$(dirname "$target")"
        done

        if [[ "$target" == "$root/${PIN_ENTRIES[$i]}" ]]; then
            add_path_pin "${PIN_ACTIONS[$i]}" "${PIN_TYPES[$i]}" "$target" "$target"
        else
            add_path_pin "${PIN_ACTIONS[$i]}" dir "$target" "$target"
        fi

        i=$((i + 1))
    done
}


# ---------------------------------------------------------------------------
#  Hide the FILE placeholders from `git status` while the session runs.
#
#  The pre-emption pass above leaves empty files in your project, and
#  `git status` in another terminal reports each one as a new file. That noise
#  invites two mistakes: committing them, or "cleaning them up" mid-session.
#  So the launcher lists them in .git/info/exclude for the duration of the
#  run, and cleanup removes the entries again.
#
#  WHY .git/info/exclude AND NOT .gitignore. Both take the same syntax and
#  both hide a path from `git status`. But .gitignore is a tracked file inside
#  the mounted tree: the agent can write it, so at exit we could not tell our
#  lines from the agent's, and a commit made from another terminal mid-session
#  would capture our temporary lines into history. .git/info/exclude is never
#  committed, and it lives inside .git — which the container masks, so the
#  agent can never see it or touch it. Only this launcher, on the host side,
#  can.
#
#  WHAT KEEPS IT SAFE. An ignore rule hides a PATH, not a file. A rule that
#  outlived the session would silently hide a real file created later at that
#  path — worse than the residue it replaces, because an empty leftover file
#  is visible noise while a leftover rule is invisible silence. Three things
#  close that hole:
#
#    * The entries sit between marker lines, and cleanup removes the block.
#    * Every launch removes a stale block BEFORE writing its own. So a run
#      killed with `kill -9`, which skips the exit trap, is healed by the
#      next run.
#    * Each entry is anchored ("/.envrc" matches only the top of the tree),
#      and an ignore rule can never hide a change to a TRACKED file — git
#      ignores apply to untracked paths only, and every placeholder was
#      absent at launch.
#
#  The exit report is not weakened either way: it scans with `find`, not git.
# ---------------------------------------------------------------------------
EXCLUDE_BEGIN="# safer-agents: session placeholders (removed at exit) -- begin"
EXCLUDE_END="# safer-agents: session placeholders -- end"

hide_placeholders_from_git() {
    local top path

    # No git on the host, or not a git repository: nothing sees the files.
    command -v git >/dev/null 2>&1 || return 0
    top="$(git -C "$HOST_PATH" rev-parse --show-toplevel 2>/dev/null)" || return 0

    # --git-path resolves the awkward layouts for us: in a worktree or a
    # submodule, .git is a FILE and the real folder is elsewhere. The answer
    # may come back relative to $HOST_PATH, so anchor it.
    if ! EXCLUDE_FILE="$(git -C "$HOST_PATH" rev-parse --git-path info/exclude 2>/dev/null)"; then
        EXCLUDE_FILE=""
        return 0
    fi
    [[ "$EXCLUDE_FILE" == /* ]] || EXCLUDE_FILE="$HOST_PATH/$EXCLUDE_FILE"

    # Heal first, write second. A stale block from a killed run must go even
    # when THIS run has no placeholders to hide — that is why this function
    # is called unconditionally.
    remove_exclude_block

    if [[ ${#PREEMPTED_FILES[@]} -eq 0 ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$EXCLUDE_FILE")"

    {
        echo "$EXCLUDE_BEGIN"
        for path in ${PREEMPTED_FILES+"${PREEMPTED_FILES[@]}"}; do
            # Only paths inside THIS repository. A placeholder in a --rw
            # folder that is its own repository stays visible there.
            [[ "$path" == "$top"/* ]] || continue
            echo "/${path#"$top"/}"
        done
        echo "$EXCLUDE_END"
    } >> "$EXCLUDE_FILE"

    echo "              The empty files are hidden from \`git status\` until then,"
    echo "              through .git/info/exclude, which the agent cannot reach."
}

# ---------------------------------------------------------------------------
#  Remove the marker block again. Called from cleanup, and by the healing
#  step above at the next launch when cleanup never ran.
#
#  The rewrite goes through a temporary file next to the original, so the
#  final `mv` is a plain rename and a crash cannot leave the file half
#  written.
# ---------------------------------------------------------------------------
remove_exclude_block() {
    local tmp

    [[ -n "$EXCLUDE_FILE" && -f "$EXCLUDE_FILE" ]] || return 0
    grep -qF "$EXCLUDE_BEGIN" "$EXCLUDE_FILE" || return 0

    tmp="$EXCLUDE_FILE.safer-agents.$$"
    if ! awk -v b="$EXCLUDE_BEGIN" -v e="$EXCLUDE_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip
        ' "$EXCLUDE_FILE" > "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi
    mv "$tmp" "$EXCLUDE_FILE"
}


# ---------------------------------------------------------------------------
#  The one call each command makes. Covers, in every mounted tree:
#
#    * .git, at any depth
#    * every path in dangerous-paths.txt
#
#  and, in the tool's own config folder, .git under anything bound back from
#  your Mac. dangerous-paths.txt is NOT applied there: that folder is already
#  handled the other way round, as a throwaway copy with named exceptions, and
#  its own command decides what those are.
# ---------------------------------------------------------------------------
# Is this mount root one the agent can write? Only --rw makes one writable.
mount_is_writable() {
    local root
    for root in ${RW_MOUNTS+"${RW_MOUNTS[@]}"}; do
        if [[ "$1" == "$root" ]]; then
            echo 1
            return 0
        fi
    done
    echo 0
}

safer_protect_paths() {
    local root i

    load_dangerous_paths

    # The project folder is always read-write. That is what makes it the tree
    # the pre-emption pass matters most in.
    mask_git_in_tree "$HOST_PATH"
    pin_dangerous_paths_in_tree "$HOST_PATH" 1
    SCAN_ROOTS+=("$HOST_PATH")

    for root in ${MOUNT_ROOTS+"${MOUNT_ROOTS[@]}"}; do
        mask_git_in_tree "$root"
        pin_dangerous_paths_in_tree "$root" "$(mount_is_writable "$root")"
        # Only writable trees can gain a file during the session, so only
        # those are worth scanning at exit.
        if [[ "$(mount_is_writable "$root")" -eq 1 ]]; then
            SCAN_ROOTS+=("$root")
        fi
    done

    # Config items bound back from your Mac by ro_back / rw_back. Host and
    # container paths differ here, so both are needed.
    i=0
    while [[ $i -lt ${#CONFIG_SCAN_HOSTS[@]} ]]; do
        mask_git_in_tree "${CONFIG_SCAN_HOSTS[$i]}" "${CONFIG_SCAN_CONTS[$i]}"
        i=$((i + 1))
    done

    # Say how many placeholders this run will create in your project. The
    # count grows with every entry added to dangerous-paths.txt, and `git
    # status` in another terminal reports all of them as new files. Saying it
    # here is cheaper than the alternative, which is somebody committing them
    # or deleting the entries that produced them.
    if [[ ${#PREEMPTED_PATHS[@]} -gt 0 ]]; then
        echo "Placeholders: ${#PREEMPTED_PATHS[@]} empty files and folders are created in the"
        echo "              mounted trees so the agent cannot create them. They are"
        echo "              removed when the session ends. See dangerous-paths.txt."
    fi

    # Keep the placeholders out of `git status`, and heal whatever a killed
    # run left in .git/info/exclude. Called even with zero placeholders,
    # because the healing half must always run.
    hide_placeholders_from_git

    # Last, and before the container starts, so the baseline is the tree as it
    # was when you launched. The placeholders do not appear in it: Docker
    # creates those at `docker run`, later than this. That is correct — an
    # empty placeholder is removed again by remove_preempted_residue, and one
    # that is NOT empty at exit is something you want to hear about.
    record_scan_baseline
}


# =============================================================================
#  SECTION 7b — Telling you what appeared during the session
#
#  WHY THIS EXISTS
#  Section 7 is a blocklist, and a blocklist has three holes that no mount can
#  close. All three are documented in dangerous-paths.txt:
#
#    * A glob entry that matches nothing yet. No mount can be prepared for
#      `evil.code-workspace`, because nobody knows the name in advance.
#    * A path created mid-session, deep in the tree. Pre-emption covers the top
#      of each tree only.
#    * The next dangerous filename nobody has thought of yet. That is what a
#      blocklist IS, and adding entries never finishes the job.
#
#  So this section stops trying to prevent and starts reporting. It records
#  what each writable tree held at launch, and lists what is new at exit. It
#  blocks nothing and it cannot break a tool. Its whole job is to make sure
#  that "read the diff before you commit" has something to point at — including
#  for files that no diff shows, because they are gitignored.
#
#  WHAT COUNTS AS INTERESTING — three questions, three answers
#      1. Which paths matching dangerous-paths.txt are NEW? A name that was
#         pre-empted cannot appear here; a deep one or a glob can.
#      2. Which `warn` entries were WRITTEN? Those are files the agent must be
#         able to edit — package.json and friends — so they are never covered
#         and they were already there. Only a change means anything.
#      3. Which executable files are NEW? That is the cheap, general answer to
#         "the list will keep needing additions": a planted auto-run file
#         usually has to be executable to be worth planting.
#
#  HOW IT IS MEASURED
#  Questions 1 and 3 share one traversal and compare against a list recorded at
#  launch. Question 2 needs no list: `find -newer` against a file stamped at
#  launch answers it directly, and that is a second traversal.
#
#  .git is pruned in both. It is masked in the container, so the agent cannot
#  have written there, and git activity on your Mac during the session would
#  otherwise fill the report with noise.
# =============================================================================

# ---------------------------------------------------------------------------
#  List everything interesting in one tree, one path per line.
#
#  Read the find expression as three alternatives tried in order:
#      -name .git -prune -o          skip .git entirely
#      \( ...entries... \) -prune -print   a dangerous name: print, do not descend
#      -type f -perm -u+x -print     any other executable file
# ---------------------------------------------------------------------------
scan_tree() {
    find "$1" \
        -name .git -prune -o \
        \( ${PIN_FIND_EXPR+"${PIN_FIND_EXPR[@]}"} \) -prune -print -o \
        -type f -perm -u+x -print 2>/dev/null
}

# ---------------------------------------------------------------------------
#  List the `warn` entries in one tree that CHANGED during the session.
#
#  A separate pass, because it asks a different question. The scan above finds
#  paths that are NEW. That is the right question for .envrc, which should
#  never appear at all. It is the wrong question for package.json, which is
#  already there and whose danger is a line added to it.
#
#  `-newer $SCAN_MARKER` answers the right one: the marker file is touched just
#  before the container starts, so anything with a later modification time was
#  written while the agent was running. No baseline, no comparison, and it
#  costs one traversal.
#
#  Note this reports a `warn` FILE. A `warn` entry naming a folder would be
#  pruned and only its own timestamp tested, which is not what you would mean.
#  Keep `warn` entries to files.
# ---------------------------------------------------------------------------
scan_warn_tree() {
    if [[ ${#WARN_FIND_EXPR[@]} -eq 0 || -z "$SCAN_MARKER" ]]; then
        return 0
    fi
    find "$1" \
        -name .git -prune -o \
        \( "${WARN_FIND_EXPR[@]}" \) -prune -newer "$SCAN_MARKER" -print \
        2>/dev/null
}

# ---------------------------------------------------------------------------
#  Record what the writable trees hold now, before the container starts.
#
#  Sorted, because the comparison at exit is `comm`, which needs sorted input.
# ---------------------------------------------------------------------------
record_scan_baseline() {
    local root

    if [[ ${#SCAN_ROOTS[@]} -eq 0 ]]; then
        return 0
    fi

    init_scratch
    SCAN_BASELINE="$SCRATCH_DIR/scan-baseline"

    for root in "${SCAN_ROOTS[@]}"; do
        scan_tree "$root"
    done | sort > "$SCAN_BASELINE"

    # Stamped LAST, so that nothing this function did can look newer than it.
    SCAN_MARKER="$SCRATCH_DIR/scan-marker"
    : > "$SCAN_MARKER"
}

# ---------------------------------------------------------------------------
#  Compare, and say what is new.
#
#  Called from cleanup, so it must survive being called when nothing was ever
#  recorded — a usage error exits long before the baseline is taken.
#
#  `comm -13 A B` prints the lines that are in B and not in A: exactly the
#  paths that were not there when the session started.
# ---------------------------------------------------------------------------
SCAN_REPORT_LIMIT=40

report_new_dangerous_paths() {
    local root now added count i
    local dangerous_hits executables changed path matched

    if [[ -z "$SCAN_BASELINE" || ! -f "$SCAN_BASELINE" ]]; then
        return 0
    fi

    now="$SCRATCH_DIR/scan-now"
    added="$SCRATCH_DIR/scan-added"
    changed="$SCRATCH_DIR/scan-changed"

    for root in "${SCAN_ROOTS[@]}"; do
        scan_tree "$root"
    done | sort > "$now"

    comm -13 "$SCAN_BASELINE" "$now" > "$added" 2>/dev/null || : > "$added"

    # The `warn` entries, which are reported on CHANGE rather than on
    # appearance. A path can land in both lists; that is honest, since it was
    # both created and written.
    : > "$changed"
    for root in "${SCAN_ROOTS[@]}"; do
        scan_warn_tree "$root"
    done | sort > "$changed"

    if [[ ! -s "$added" && ! -s "$changed" ]]; then
        return 0
    fi

    # Split the new paths in two. A path that matches an entry in
    # dangerous-paths.txt is the serious half; a merely executable file is the
    # broad net, and most of what it catches is legitimate.
    dangerous_hits="$SCRATCH_DIR/scan-dangerous"
    executables="$SCRATCH_DIR/scan-exec"
    : > "$dangerous_hits"
    : > "$executables"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        matched=0
        i=0
        while [[ $i -lt ${#PIN_ENTRIES[@]} ]]; do
            # Unquoted on the right of ==, so a glob entry matches as a
            # pattern. Same rule as pin_dangerous_paths_in_tree.
            if [[ "$path" == */${PIN_ENTRIES[$i]} ]]; then
                matched=1
                break
            fi
            i=$((i + 1))
        done

        if [[ $matched -eq 0 ]]; then
            printf '%s\n' "$path" >> "$executables"
        elif [[ "${PIN_ACTIONS[$i]}" == "warn" ]]; then
            # A watched name that did not exist before. It belongs in the
            # watched list, not under a heading that implies it was covered.
            printf '%s\n' "$path" >> "$changed"
        else
            printf '%s\n' "$path" >> "$dangerous_hits"
        fi
    done < "$added"

    # The two paths into $changed can name the same file twice.
    sort -u "$changed" -o "$changed" 2>/dev/null || true

    {
        echo ""
        echo "NEW AUTO-RUN CANDIDATES"
        echo "-----------------------"
        echo "# Files that were not in the mounted trees when this session started."
        echo "# Nothing here was blocked. This is the half of dangerous-paths.txt"
        echo "# that a list cannot cover: deep paths, unknown names, and names"
        echo "# nobody has added yet. Read them before you commit or run anything."
        echo ""

        if [[ -s "$dangerous_hits" ]]; then
            count="$(wc -l < "$dangerous_hits" | tr -d ' ')"
            echo "  Matching dangerous-paths.txt ($count):"
            head -n "$SCAN_REPORT_LIMIT" "$dangerous_hits" | sed 's/^/    /'
            if [[ "$count" -gt "$SCAN_REPORT_LIMIT" ]]; then
                echo "    ... and $((count - SCAN_REPORT_LIMIT)) more"
            fi
            echo ""
        fi

        if [[ -s "$changed" ]]; then
            count="$(wc -l < "$changed" | tr -d ' ')"
            echo "  Watched files written during the session ($count):"
            echo "  # 'warn' entries in dangerous-paths.txt. These are never"
            echo "  # covered — the agent has to be able to edit them. Read"
            echo "  # what changed before you install or commit."
            head -n "$SCAN_REPORT_LIMIT" "$changed" | sed 's/^/    /'
            if [[ "$count" -gt "$SCAN_REPORT_LIMIT" ]]; then
                echo "    ... and $((count - SCAN_REPORT_LIMIT)) more"
            fi
            echo ""
        fi

        if [[ -s "$executables" ]]; then
            count="$(wc -l < "$executables" | tr -d ' ')"
            echo "  New executable files ($count):"
            head -n "$SCAN_REPORT_LIMIT" "$executables" | sed 's/^/    /'
            if [[ "$count" -gt "$SCAN_REPORT_LIMIT" ]]; then
                echo "    ... and $((count - SCAN_REPORT_LIMIT)) more"
            fi
        fi
    } > "$SCRATCH_DIR/scan-report"

    # To the terminal, so it is seen now.
    cat "$SCRATCH_DIR/scan-report"

    # And into this run's connection log, so it is still there next week.
    # RUN_LOG is empty when --offline was used, since no gatekeeper ran.
    if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
        cat "$SCRATCH_DIR/scan-report" >> "$RUN_LOG"
    fi

    return 0
}


# =============================================================================
#  SECTION 8 — Mounting extra folders
# =============================================================================

# ---------------------------------------------------------------------------
#  Ask before granting write access outside the project.
#
#  WHY THIS EXISTS
#  --rw is the one flag that can change your Mac outside the folder you are
#  working in. Until this was added, the only guard was reject_config_path,
#  which refuses a path that overlaps the tool config or this script's folder.
#  That check refuses `--rw ~` — but only as a SIDE EFFECT, because ~ contains
#  ~/.claude. It says nothing about `--rw ~/Documents`, which went through
#  silently and handed the agent a large part of your home directory.
#
#  WHAT IS AND IS NOT PROTECTED IN AN --rw FOLDER
#  A --rw tree is not unguarded. safer_protect_paths applies .git masking and
#  every entry in dangerous-paths.txt to it, exactly as it does to the project
#  folder, and pre-empts the absent ones. But that list covers a set of NAMES.
#  It says nothing about the rest of the folder's contents. So the question
#  below is about the contents, not about the auto-run files.
#
#  THREE OUTCOMES
#      inside the project      no question. That tree is already writable.
#      contains the project    refused. Run the command from there instead.
#      anywhere else           type yes.
#
#  SAFER_ASSUME_YES=1 answers for you. It is meant for unattended runs. With
#  no terminal and no such variable the command refuses rather than hangs.
# ---------------------------------------------------------------------------
confirm_rw_mount() {
    local raw="$1"
    local host="$2"
    local project reply

    # add_mount runs while the command line is being read, which is BEFORE
    # safer_check_workdir sets HOST_PATH. So work it out the same way that
    # function does. -P resolves symlinks, so both agree.
    project="${HOST_PATH:-$(pwd -P)}"

    # Already writable. Nothing new is being granted.
    if [[ "$host" == "$project" || "$host" == "$project"/* ]]; then
        return 0
    fi

    # A folder that CONTAINS the project, or $HOME itself. There is no reading
    # of this that is not an accident: the project is already writable, so the
    # only thing such a mount adds is everything else on the way up.
    #
    # reject_config_path already refuses most of these, because the tool config
    # sits under $HOME. That is incidental and would stop working if the config
    # moved. This is the rule it was standing in for.
    if [[ "$host" == "$HOME" || "$project" == "$host"/* ]]; then
        echo "Error: refusing --rw on '$raw'" >&2
        echo "That folder contains the folder you are working in, which is already" >&2
        echo "read-write. Mounting it would add write access to everything above" >&2
        echo "your project and nothing you need." >&2
        exit 1
    fi

    if [[ "${SAFER_ASSUME_YES:-}" == "1" ]]; then
        echo "--rw $host   (outside the project; allowed by SAFER_ASSUME_YES)"
        return 0
    fi

    # -t 0 asks whether standard input is a terminal. Without one there is
    # nobody to answer, and a silent yes is the answer this whole function
    # exists to prevent.
    if [[ ! -t 0 ]]; then
        echo "Error: --rw '$raw' points outside the folder you are working in," >&2
        echo "and there is no terminal to confirm it at." >&2
        echo "Set SAFER_ASSUME_YES=1 for an unattended run." >&2
        exit 1
    fi

    echo ""
    echo "  --rw gives the agent WRITE access to a folder outside your project:"
    echo ""
    echo "      $host"
    echo ""
    echo "  Anything the agent writes there lands on your Mac and stays after the"
    echo "  session ends. .git and the paths in dangerous-paths.txt are covered"
    echo "  in this folder too, but that is a list of names. The rest of the"
    echo "  folder is open."
    echo ""
    printf "  Type yes to allow it: "
    read -r reply
    echo ""

    if [[ "$reply" != "yes" ]]; then
        echo "Refused. Nothing was started." >&2
        exit 1
    fi
}

add_mount() {
    local MODE="$1"       # "ro" or "rw"
    local RAW="$2"        # what the user typed
    local HOST

    if [[ ! -e "$RAW" ]]; then
        echo "Error: path does not exist: $RAW" >&2
        exit 1
    fi

    # realpath turns a relative path such as ../../contrib into a full one and
    # resolves any symlinks. Everything after this works with the real path.
    HOST="$(realpath "$RAW")"

    reject_git_path "$RAW" "$HOST"
    reject_config_path "$RAW" "$HOST"
    check_mount_path "$HOST"

    MOUNT_ROOTS+=("$HOST")

    # The folder is mounted at the SAME path inside the container as on your
    # Mac. That keeps error messages and file references meaningful in both
    # places.
    #
    # READ-ONLY IS THE DEFAULT, and --rw is the only way to get anything else.
    # Extra folders are nearly always reference material: contrib modules the
    # agent should read to understand an API, a library it needs the source of.
    # Reading is what they are for. Making that the default means the risky
    # case is the one you have to ask for by name, and the one that shows up in
    # your shell history as --rw.
    if [[ "$MODE" == "rw" ]]; then
        confirm_rw_mount "$RAW" "$HOST"
        RW_MOUNTS+=("$HOST")
        EXTRA_MOUNTS+=(--mount "type=bind,src=$HOST,dst=$HOST")
        # Say it at launch as well as in the log at exit. A writable folder is
        # worth seeing before the session, not only after it.
        echo "Writable: $HOST   (--rw)"
    else
        EXTRA_MOUNTS+=(--mount "type=bind,src=$HOST,dst=$HOST,readonly")
    fi
}


# =============================================================================
#  SECTION 9 — The config strategy
#
#  THE CONFIG STRATEGY, AND WHY IT IS THIS ONE
#
#  All three tools keep their settings in a folder in your home directory. The
#  obvious approach is to mount that folder read-write and pin the dangerous
#  files read-only on top. That approach is not used here, because it has two
#  problems.
#
#  1. It breaks saving settings, and NOT because of the read-only flag.
#     These tools save a setting by writing settings.json.tmp... and then
#     renaming it over the real file. A single-file bind mount IS a mount
#     point, and Linux refuses to let a rename replace a mount point. So the
#     save fails with EBUSY — and it would fail even if the mount were
#     writable.
#
#  2. It is a blocklist. It protects the paths someone thought of. Every new
#     config file a tool learns to read is unprotected until these scripts are
#     updated to match. Codex's hooks.json, which runs commands on your Mac, is
#     the kind of path such a list misses.
#
#  So the strategy is inverted: the container gets a THROWAWAY COPY of the
#  config folder, and only what genuinely has to be shared is bound back.
#
#      the folder itself   a real, writable directory in the scratch area,
#                          deleted when the session ends
#      copied in           the files a tool rewrites. Real FILES, not mount
#                          points, so renames work and settings can be saved
#      bound back r/o      credentials, and the things you want visible
#      bound back r/w      only what must survive the session
#
#  WHY THE HOOK RISK GOES AWAY RATHER THAN BEING CONTAINED
#
#  Settings files hold hooks, status-line commands and MCP server definitions —
#  all shell commands. The danger was never that they run in the container;
#  that is just the sandbox running something. The danger was that they run ON
#  YOUR MAC the next time you start the tool there. Your Mac never reads a
#  copy, so the agent can write whatever it likes into one.
#
#  A SIDE EFFECT WORTH KNOWING
#
#  Prompt history and session stores are not bound back. They hold prompts and
#  file contents from every other project you have worked on, which is not
#  something a sandbox limited to one project should be able to read. They are
#  now per-session and disappear on exit. For claude, this project's transcript
#  is the one exception — see safer-claude.
# =============================================================================

# ---------------------------------------------------------------------------
#  Hand in single-file configs as throwaway copies.
#
#  Only for files outside the config folder; everything inside it is handled by
#  copy_in below.
# ---------------------------------------------------------------------------
apply_config_copies() {
    local i=0
    local src dst tmp

    while [[ $i -lt ${#COPY_SRCS[@]} ]]; do
        src="${COPY_SRCS[$i]}"
        dst="${COPY_DSTS[$i]}"

        init_scratch
        tmp="$SCRATCH_DIR/config-$i"
        i=$((i + 1))

        if [[ -f "$src" ]]; then
            cp "$src" "$tmp"
        elif [[ "$src" == *.json ]]; then
            printf '%s\n' '{}' > "$tmp"
        else
            : > "$tmp"
        fi

        chmod 0600 "$tmp"
        check_mount_path "$tmp"
        check_mount_path "$dst"
        CONFIG_MOUNTS+=(--mount "type=bind,src=$tmp,dst=$dst")
    done
}

# Set by config_root, used by the helpers that follow it.
# ---------------------------------------------------------------------------
#  A WRITABLE $HOME, WITHOUT ROOT-OWNED HOLES IN IT
#
#  Section 14 mounts a tmpfs over $HOME, because the container filesystem is
#  read-only. That alone is not enough, and the reason took three attempts to
#  find, so it is written down here in full.
#
#  When a bind mount names a destination that does not exist, Docker creates
#  the missing folders for you. The Docker daemon runs as root, so it creates
#  them owned by ROOT with mode 0755. We run the container with YOUR user id.
#
#  So mounting the opencode data folder at
#
#      /home/agent/.local/share/opencode
#
#  makes Docker create /home/agent/.local and /home/agent/.local/share inside
#  our writable tmpfs, both root-owned and both closed to us. Read from inside
#  a running container, that is:
#
#      drwxrwxrwt 4 root root  /home/agent            <- our tmpfs
#      drwxr-xr-x 3 root root  /home/agent/.local     <- Docker invented this
#      drwxr-xr-x 3 root root  /home/agent/.local/share
#
#  The folder we asked for is writable. Its parents are not. opencode then
#  tries to create its sibling, $HOME/.local/state, and fails with
#
#      EACCES: permission denied, mkdir '/home/agent/.local/state'
#
#  which is the same fault as the earlier EROFS, one level further up.
#
#  The fix is to leave none of those parents for Docker to invent. Every folder
#  between $HOME and a mount destination gets its own writable tmpfs. The
#  destination itself still lands on top, because Docker applies mounts in
#  order of destination depth.
#
#  This is recorded automatically, from config_root and add_copy, rather than
#  written out by hand. A hand-written list would be correct today and wrong
#  the next time a tool moves its config folder.
# ---------------------------------------------------------------------------

#  A tmpfs the agent can WRITE in. Compare tmpfs_mount_arg in section 7, which
#  makes an unwritable one for hiding paths.
#
#  mode=1777 is the mode /tmp uses: anyone may create, but only the owner of a
#  file may remove it. It has to be world-writable, because a tmpfs is owned by
#  root, there is no `agent` user in the image, and we run as you. uid= and gid=
#  would be tighter, but 1777 is the form seen working in a real container, and
#  this is not the place to trade a known result for a guess.
#
#  exec is here because the DEFAULT IS noexec, and --mount cannot turn it off.
#  This was checked inside a running container, where a mount written as
#  --mount type=tmpfs,dst=/home/agent,tmpfs-mode=1777 reported:
#
#      tmpfs on /home/agent type tmpfs (rw,nosuid,nodev,noexec,...)
#
#  That form accepts only tmpfs-size and tmpfs-mode; every other option keeps
#  its default. The older "--tmpfs dest:options" form passes options straight
#  to the kernel, so it is the only one that can say exec. noexec under $HOME
#  breaks any tool that unpacks a helper binary into its own cache.
#
#  512 MB is a ceiling, not a reservation — memory is used only as files are
#  written. It is generous because these tools unpack caches into $HOME.
writable_tmpfs_arg() {
    printf '%s:rw,exec,mode=1777,size=512m' "$1"
}

#  Record every folder strictly between $HOME and $1, so that build_home_mounts
#  can cover each one. Call this with a mount DESTINATION, not a host path.
#
#  Paths outside $HOME are ignored: those are the project and the extra
#  folders, which are real bind mounts and not our business here.
note_home_parents() {
    local dst="$1"
    local rest parent

    case "$dst" in
        "$CONTAINER_HOME"/?*) ;;
        *) return 0 ;;
    esac

    # The part after "$HOME/", for example ".local/share/opencode".
    rest="${dst#"$CONTAINER_HOME"/}"
    parent="$CONTAINER_HOME"

    # Walk the components, stopping BEFORE the last one. The last one is the
    # mount destination itself, which Docker covers with the real mount.
    while [[ "$rest" == */* ]]; do
        parent="$parent/${rest%%/*}"     # add the leading component
        rest="${rest#*/}"                # and drop it from what is left

        case "$HOME_DIRS_SEEN" in
            *$'\n'"$parent"$'\n'*) continue ;;
        esac
        HOME_DIRS_SEEN="$HOME_DIRS_SEEN$parent"$'\n'

        check_mount_path "$parent"
        HOME_MOUNTS+=(--tmpfs "$(writable_tmpfs_arg "$parent")")
    done
}

# ---------------------------------------------------------------------------
#  GIVE THE USER ID A NAME
#
#  We run the container with --user "$(id -u):$(id -g)" so that files the agent
#  creates in your project belong to you. But the image has no user with that
#  id, so the id has no entry in /etc/passwd. The visible symptom is a shell
#  prompt reading
#
#      I have no name!@8c74e9a211a4:/Users/...$
#
#  and `whoami` failing outright. That looks cosmetic. It is not.
#
#  Anything that asks the system "who am I, and where is my home?" goes through
#  the password database. In Node and Bun that is os.userInfo(), which THROWS
#  for an unknown id rather than returning a default. A tool that calls it
#  while starting up dies with whatever its own error handler prints — often
#  something as unhelpful as "Unexpected error".
#
#  The fix is not to add a user to the image: your id is decided on your Mac,
#  at run time, and a Linux host would give a different one. So generate the
#  two files per run and mount them read-only. Read-only matters — this is the
#  file that says which id is privileged.
#
#  Only three entries each. The container drops every capability and runs as
#  one id, so the rest of a distribution's list has nothing to do here.
# ---------------------------------------------------------------------------
build_identity_files() {
    local uid gid passwd_file group_file

    uid="$(id -u)"
    gid="$(id -g)"

    init_scratch
    passwd_file="$SCRATCH_DIR/passwd"
    group_file="$SCRATCH_DIR/group"

    #  The shell is bash because the Dockerfiles install it and because
    #  `safer-opencode -- bash` should land somewhere that exists.
    {
        echo "root:x:0:0:root:/root:/bin/bash"
        echo "agent:x:$uid:$gid:agent:$CONTAINER_HOME:/bin/bash"
        echo "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin"
    } > "$passwd_file"

    #  The group name is ours on purpose. On macOS gid 20 is "staff"; in Debian
    #  it is "dialout", which is why `id` inside the container reported a group
    #  name that has nothing to do with anything. Naming it "agent" stops that
    #  being a distraction in a bug report.
    {
        echo "root:x:0:"
        echo "agent:x:$gid:"
        echo "nogroup:x:65534:"
    } > "$group_file"

    chmod 0444 "$passwd_file" "$group_file"
    check_mount_path "$passwd_file"
    check_mount_path "$group_file"

    IDENTITY_MOUNTS+=(--mount "type=bind,src=$passwd_file,dst=/etc/passwd,readonly")
    IDENTITY_MOUNTS+=(--mount "type=bind,src=$group_file,dst=/etc/group,readonly")
}

#  Assemble the $HOME mounts. Called by safer_run, after every config_root and
#  add_copy has had its say.
build_home_mounts() {
    local dst

    # $HOME itself, first. Without this the tools cannot write in $HOME at all
    # and stop with EROFS, because the container filesystem is read-only.
    HOME_MOUNTS+=(--tmpfs "$(writable_tmpfs_arg "$CONTAINER_HOME")")

    # Then the parents of everything mounted underneath it.
    for dst in ${COPY_DSTS+"${COPY_DSTS[@]}"}; do
        note_home_parents "$dst"
    done
    for dst in ${CONFIG_DSTS+"${CONFIG_DSTS[@]}"}; do
        note_home_parents "$dst"
    done
}


CUR_HOST=""       # the folder on your Mac
CUR_CONT=""       # where it appears in the container
CUR_BASE=""       # the throwaway copy in the scratch area

# ---------------------------------------------------------------------------
#  Begin a throwaway copy of one config folder.
#
#  $1 host path   $2 container path   $3 short name for the scratch folder
#
#  Call this first, then copy_in / ro_back / rw_back for that folder. A tool
#  with two config folders (opencode) calls it twice.
# ---------------------------------------------------------------------------
config_root() {
    init_scratch

    CUR_HOST="$1"
    CUR_CONT="$2"
    CUR_BASE="$SCRATCH_DIR/$3"

    mkdir -p "$CUR_BASE"
    chmod 0700 "$CUR_BASE"
    check_mount_path "$CUR_BASE"
    check_mount_path "$CUR_CONT"

    AUTH_MOUNTS+=(--mount "type=bind,src=$CUR_BASE,dst=$CUR_CONT")

    # Remembered so build_home_mounts can make this folder's parents writable.
    CONFIG_DSTS+=("$CUR_CONT")
}

# ---------------------------------------------------------------------------
#  Copy one file into the throwaway folder, as a real writable file.
#
#  $1 file name
#  $2 what to do when your Mac does not have it:
#       json    create it containing {}
#       empty   create it empty
#       (omit)  leave it absent
#
#  These are the files that must NOT be mount points, or saving a setting
#  fails. The tool may rewrite them freely; the writes die with the container.
# ---------------------------------------------------------------------------
copy_in() {
    local name="$1"
    local missing="${2:-}"

    if [[ -f "$CUR_HOST/$name" ]]; then
        cp "$CUR_HOST/$name" "$CUR_BASE/$name"
    elif [[ "$missing" == "json" ]]; then
        printf '%s\n' '{}' > "$CUR_BASE/$name"
    elif [[ "$missing" == "empty" ]]; then
        : > "$CUR_BASE/$name"
    else
        return 0
    fi

    chmod 0600 "$CUR_BASE/$name"
}

# ---------------------------------------------------------------------------
#  Create one file in the throwaway folder from a COMMAND's output.
#
#  $1 file name        everything after it is the command and its arguments
#
#  Same result as copy_in — a real writable file, not a mount point — but the
#  content comes from a command instead of from your Mac's config folder. Needed
#  because macOS keeps some secrets in the Keychain rather than in any file.
#
#  The command runs on YOUR MAC, in this launcher, before the container starts.
#
#  Returns 0 only when the command succeeded AND produced something. On failure
#  it leaves no file behind, so the caller can fall back to another source.
# ---------------------------------------------------------------------------
seed_in() {
    local name="$1"
    shift

    local dest="$CUR_BASE/$name"
    local tmp="$dest.seed"

    if "$@" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        mv "$tmp" "$dest"
        chmod 0600 "$dest"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

# ---------------------------------------------------------------------------
#  Bind items from your Mac back into the copy, READ-ONLY.
#
#  Takes any number of names. Each is skipped silently if absent — no
#  placeholder is created, because under this strategy a missing item simply
#  does not exist in the container and anything the agent puts there lands in
#  the throwaway copy.
#
#  Read-only because these are real files on your Mac. Several of them are
#  loaded by name the next time you run the tool there.
# ---------------------------------------------------------------------------
ro_back() {
    local name

    for name in "$@"; do
        [[ -e "$CUR_HOST/$name" ]] || continue
        check_mount_path "$CUR_HOST/$name"
        check_mount_path "$CUR_CONT/$name"
        CONFIG_MOUNTS+=(--mount "type=bind,src=$CUR_HOST/$name,dst=$CUR_CONT/$name,readonly")

        # Remember it, so section 7 can hide any .git inside. Read-only is not
        # enough on its own: a .git bound in this way is still a folder full of
        # hooks and remote URLs for the agent to read.
        CONFIG_SCAN_HOSTS+=("$CUR_HOST/$name")
        CONFIG_SCAN_CONTS+=("$CUR_CONT/$name")
    done
}

# ---------------------------------------------------------------------------
#  Bind one item back READ-WRITE, so it survives the session. Created on your
#  Mac if missing.
#
#  Use sparingly: whatever is bound this way, the agent can write to your Mac.
#  Docker creates a missing destination path, so intermediate folders do not
#  need to exist in the copy first.
# ---------------------------------------------------------------------------
rw_back() {
    local name="$1"

    mkdir -p "$CUR_HOST/$name"
    check_mount_path "$CUR_HOST/$name"
    check_mount_path "$CUR_CONT/$name"
    CONFIG_MOUNTS+=(--mount "type=bind,src=$CUR_HOST/$name,dst=$CUR_CONT/$name")

    # This one is WRITABLE, so hiding any .git inside matters more here than in
    # ro_back. See section 7.
    CONFIG_SCAN_HOSTS+=("$CUR_HOST/$name")
    CONFIG_SCAN_CONTS+=("$CUR_CONT/$name")
}


# =============================================================================
#  SECTION 10 — The network
#
#  This is the part that stops data leaving and stops instructions arriving.
# =============================================================================

# ---------------------------------------------------------------------------
#  Build the list of permitted destinations for this run.
#
#  Joins allowlist-common.txt and allowlist-<tool>.txt, then appends anything
#  given with --allow. The result is written next to the allowlists and mounted
#  into the gatekeeper.
#
#  Why write a combined file instead of mounting the originals: tinyproxy reads
#  one filter file, --allow needs to work without editing a file you keep, and
#  exactly one file is mounted whether or not --allow was used.
#
#  Why in this folder rather than the temp folder: the launcher tree is
#  definitely shared with Docker Desktop's virtual machine, since Docker builds
#  from docker/ inside it. The system temp folder is not reliably shared; see
#  init_scratch in section 4 for the same problem.
# ---------------------------------------------------------------------------
build_effective_allowlist() {
    local host escaped

    if [[ ! -f "$ALLOWLIST_COMMON" ]]; then
        echo "Error: shared allowlist not found: $ALLOWLIST_COMMON" >&2
        exit 1
    fi
    if [[ ! -f "$ALLOWLIST_TOOL" ]]; then
        echo "Error: allowlist for $TOOL not found: $ALLOWLIST_TOOL" >&2
        exit 1
    fi
    if [[ ! -f "$PROXY_CONF" ]]; then
        echo "Error: proxy config not found: $PROXY_CONF" >&2
        exit 1
    fi

    # $$ is this script's process id, so two runs at once do not clash.
    EFFECTIVE_ALLOWLIST="$PROXY_DIR/.allowlist.effective.$TOOL.$$"

    cat "$ALLOWLIST_COMMON" "$ALLOWLIST_TOOL" > "$EFFECTIVE_ALLOWLIST"

    for host in ${EXTRA_ALLOW+"${EXTRA_ALLOW[@]}"}; do
        # Turn a plain hostname into a safe anchored pattern:
        #
        #     www.php.net   ->   ^www\.php\.net$
        #
        # The dots must be escaped because in a regular expression an
        # unescaped dot means "any character", and the ^ and $ must be there
        # because an unanchored pattern matches anywhere in the hostname. Left
        # as-is, "api.anthropic.com" would also match
        # "evil-api-anthropic-com.attacker.net".
        escaped="$(printf '%s' "$host" | sed 's/\./\\./g')"
        printf '^%s$\n' "$escaped" >> "$EFFECTIVE_ALLOWLIST"
        echo "Allowing for this run only: $host"
    done

    chmod 0644 "$EFFECTIVE_ALLOWLIST"       # the gatekeeper must be able to read it
    check_mount_path "$EFFECTIVE_ALLOWLIST"
}

# ---------------------------------------------------------------------------
#  Make sure the gatekeeper image exists.
#
#  Building it is cheap (Alpine plus one package) and Docker caches the layers,
#  so a rebuild after the first time is nearly instant.
# ---------------------------------------------------------------------------
ensure_proxy_image() {
    if docker image inspect "$PROXY_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    echo "Building the gatekeeper image ($PROXY_IMAGE)..."
    docker build \
        -f "$DOCKER_DIR/Dockerfile.proxy" \
        -t "$PROXY_IMAGE" \
        "$DOCKER_DIR"
}

# ---------------------------------------------------------------------------
#  Create the sealed network and start the gatekeeper on it.
# ---------------------------------------------------------------------------
start_network() {
    local subnet chosen=""

    NET_NAME="safer-$TOOL-net-$$"
    PROXY_NAME="safer-$TOOL-proxy-$$"

    # --- The sealed network -----------------------------------------------
    #
    #  --internal is the whole point. Containers on this network can reach each
    #  other and NOTHING else: no internet, no access to your Mac, no other
    #  Docker networks.
    #
    #  A side effect worth knowing: name lookups for outside addresses stop
    #  working, because there is no route to any nameserver. Docker's built-in
    #  resolver still answers for container names on this network, which is all
    #  the agent needs — it connects to the gatekeeper by name, and the
    #  gatekeeper does the real lookups. So name lookups become part of the
    #  allowlist too, which also closes the trick of smuggling data out inside
    #  the lookups themselves.
    #
    #  --subnet fixes the address range so the `Allow` line in tinyproxy.conf
    #  can name it. We try each range in the pool until one is free, so a
    #  second session — of this tool or another — does not fail here.
    for subnet in "${SUBNET_POOL[@]}"; do
        if docker network create \
                --internal \
                --subnet "$subnet" \
                "$NET_NAME" >/dev/null 2>&1; then
            chosen="$subnet"
            break
        fi
    done

    if [[ -z "$chosen" ]]; then
        echo "Error: could not create a sealed network." >&2
        echo "All ${#SUBNET_POOL[@]} address ranges in the pool are in use by other" >&2
        echo "Docker networks. Either stop some containers, or edit SUBNET_POOL in" >&2
        echo "lib/safer-common.sh and the Allow line in proxy/tinyproxy.conf." >&2
        exit 1
    fi
    NET_CREATED=1

    # --- The gatekeeper ---------------------------------------------------
    #
    #  -d                     run in the background; we need the terminal for
    #                         the agent
    #  --network-alias proxy  the name the agent uses: http://proxy:8888
    #  --read-only            the container's own filesystem cannot be changed
    #  --tmpfs /tmp           except a small area in memory, for the pid file
    #  --cap-drop ALL         remove every Linux privilege
    #  --security-opt ...     and forbid regaining any
    #  --pull=never           never fetch from Docker Hub. Without this, a typo
    #                         in the image name would make Docker download and
    #                         run something from the internet
    #  the two mounts         config and allowlist, both read-only, so nothing
    #                         inside the gatekeeper can rewrite the rules it is
    #                         enforcing
    docker run -d \
        --name "$PROXY_NAME" \
        --network "$NET_NAME" \
        --network-alias proxy \
        --read-only \
        --tmpfs /tmp \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --pull=never \
        --mount "type=bind,src=$PROXY_CONF,dst=/etc/tinyproxy/tinyproxy.conf,readonly" \
        --mount "type=bind,src=$EFFECTIVE_ALLOWLIST,dst=/etc/tinyproxy/allowlist.txt,readonly" \
        "$PROXY_IMAGE" >/dev/null
    PROXY_STARTED=1

    # --- Give the gatekeeper a way out ------------------------------------
    #
    #  It is currently on the sealed network only, so it cannot reach the
    #  internet either. Attaching it to Docker's normal "bridge" network as
    #  well makes it the single door between the two.
    #
    #  The agent is NOT attached to the bridge. That is the whole design.
    docker network connect bridge "$PROXY_NAME" >/dev/null

    #  IF THE FIRST RUN FAILS, LOOK HERE FIRST.
    #
    #  The most likely problem is name lookups inside the gatekeeper. It is
    #  attached to a sealed network as well as a normal one, and Docker's
    #  built-in resolver occasionally will not forward outside queries for a
    #  container in that position. The symptom is every destination failing,
    #  including the model API, with a name-resolution error in:
    #
    #      docker logs safer-$TOOL-proxy-<number>
    #
    #  The fix is to give the gatekeeper a resolver of its own — add a line
    #  such as `--dns 1.1.1.1 \` to the `docker run` above. It is left out by
    #  default so that no third-party DNS service is used without you choosing
    #  it.
    wait_for_proxy
}

# ---------------------------------------------------------------------------
#  Wait until the gatekeeper is actually listening.
#
#  Without this the agent can start first, make its first request, and get a
#  connection error that looks like a configuration problem.
#
#  `nc -z` tries to open a connection and reports success or failure without
#  sending anything. We run it inside the gatekeeper with `docker exec`.
# ---------------------------------------------------------------------------
wait_for_proxy() {
    local tries=0

    while [[ $tries -lt 50 ]]; do
        if docker exec "$PROXY_NAME" nc -z 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 0.2
    done

    echo "Warning: the gatekeeper did not report ready within 10 seconds." >&2
    echo "Continuing anyway. If the agent cannot connect, check:" >&2
    echo "  docker logs $PROXY_NAME" >&2
}

# ---------------------------------------------------------------------------
#  Set up the network and collect the arguments `docker run` needs for it.
#
#  A command that wants something extra on the sealed network — safer-opencode
#  and its Ollama forwarder — defines a function called
#  safer_extra_network_setup, which is called here if it exists.
# ---------------------------------------------------------------------------
safer_setup_network() {
    NET_ARGS=()

    if [[ "$OFFLINE" -eq 1 ]]; then
        # --network none means no network interface at all, not even a loopback
        # route to anywhere. The agent cannot reach the model API, so this is
        # only useful with `-- bash` for looking at code locally.
        NET_ARGS=(--network none)
        echo "Offline mode: the container has no network at all."
        return 0
    fi

    build_effective_allowlist
    ensure_proxy_image
    start_network

    # `declare -F name` succeeds only if a function of that name exists.
    if declare -F safer_extra_network_setup >/dev/null; then
        safer_extra_network_setup
    fi

    # These tell the agent to send its requests to the gatekeeper.
    #
    # Important: these variables are a REQUEST, not the enforcement. An agent
    # that runs code could unset them. It gains nothing — the gatekeeper is the
    # only route off the sealed network, so ignoring it reaches nothing at all.
    # The network is the control; these variables just save the agent from
    # having to guess.
    #
    # Both upper and lower case are set because different libraries look for
    # different spellings.
    #
    # NO_PROXY lists names to contact DIRECTLY, without going through the
    # gatekeeper. It holds only names that exist INSIDE the sealed network, so
    # "direct" never means "out to the internet unchecked".
    NET_ARGS=(
        --network "$NET_NAME"
        --env "HTTPS_PROXY=http://proxy:$PROXY_PORT"
        --env "HTTP_PROXY=http://proxy:$PROXY_PORT"
        --env "https_proxy=http://proxy:$PROXY_PORT"
        --env "http_proxy=http://proxy:$PROXY_PORT"
        --env "NO_PROXY=$NO_PROXY_HOSTS"
        --env "no_proxy=$NO_PROXY_HOSTS"
    )

    echo "Network: sealed, outbound only through the gatekeeper."
    echo "Allowed destinations:"
    # [[:space:]] rather than \s — macOS grep does not understand \s.
    grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$EFFECTIVE_ALLOWLIST" | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
#  Save this run's blocked connections to connection_logs/.
#
#  Called from cleanup(), before the gatekeeper container is destroyed.
#
#  The file is named <tool>-<timestamp>.log, so the three commands' logs sit
#  side by side and are still easy to tell apart and to filter:
#
#      ls connection_logs/opencode-*
#
#  Remember that tinyproxy is set to LogLevel Notice, which means successful
#  connections are never written down in the first place. So what we collect
#  here is refusals and genuine proxy errors — never a record of the pages the
#  agent legitimately read.
# ---------------------------------------------------------------------------
save_connection_log() {
    local raw stamp blocked ollama_raw

    mkdir -p "$LOG_DIR"

    stamp="$(date +%Y-%m-%dT%H-%M-%S)"
    RUN_LOG="$LOG_DIR/$TOOL-$stamp.log"

    # Collect the gatekeeper's output. 2>&1 merges its error output in, since
    # tinyproxy writes some messages there.
    init_scratch
    raw="$SCRATCH_DIR/proxy.raw"
    docker logs "$PROXY_NAME" >"$raw" 2>&1 || true

    # Collect the Ollama forwarder's output too, if this command started one.
    # It logs one line per refused request and nothing else.
    ollama_raw="$SCRATCH_DIR/ollama.raw"
    : > "$ollama_raw"
    if [[ -n "$OLLAMA_NAME" ]]; then
        docker logs "$OLLAMA_NAME" 2>&1 \
            | grep -F 'DENIED' > "$ollama_raw" || true
    fi

    # Pull out just the refusal lines. They look like:
    #
    #   NOTICE  Aug 25 14:03:12 [7]: Proxying refused on filtered domain "api.drupal.org"
    #
    # The sed expression takes whatever is inside the double quotes, which is
    # the hostname. Then sort | uniq -c counts repeats, and sort -rn puts the
    # most frequent first.
    local rw
    blocked="$SCRATCH_DIR/proxy.blocked"
    grep -Ei 'refused|denied' "$raw" 2>/dev/null \
        | grep '"' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | sort \
        | uniq -c \
        | sort -rn \
        > "$blocked" || true

    # Write the report.
    {
        echo "# safer-$TOOL — blocked connection attempts"
        echo "#"
        echo "# run at:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "# tool:       $TOOL"
        echo "# workdir:    $HOST_PATH   (read-write)"
        if [[ ${#RW_MOUNTS[@]} -gt 0 ]]; then
            # Worth recording. Everything else the agent could reach was
            # read-only, so if something on your Mac changed unexpectedly,
            # these are the only places it could have happened.
            for rw in "${RW_MOUNTS[@]}"; do
                echo "# --rw:       $rw   (read-write)"
            done
        fi
        echo "# allowlists: $ALLOWLIST_COMMON"
        echo "#             $ALLOWLIST_TOOL"
        if [[ ${#EXTRA_ALLOW[@]} -gt 0 ]]; then
            echo "# --allow:    ${EXTRA_ALLOW[*]}"
        fi
        echo "#"
        echo "# Successful connections are deliberately NOT recorded."
        echo ""

        if [[ -s "$blocked" ]]; then          # -s = file exists and is not empty
            echo "BLOCKED HOSTS (attempts, most frequent first)"
            echo "---------------------------------------------"
            cat "$blocked"
        else
            echo "BLOCKED HOSTS"
            echo "-------------"
            echo "  (none — every destination the agent tried was on the allowlist)"
        fi

        # The Ollama forwarder is a separate container with its own log. Its
        # refusals are requests to Ollama endpoints that are not inference —
        # model downloads, uploads, deletions. One of those is worth looking at
        # properly: nothing legitimate in an editing session asks for them.
        if [[ -s "$ollama_raw" ]]; then
            echo ""
            echo "REFUSED OLLAMA REQUESTS"
            echo "-----------------------"
            echo "# Model-management requests the forwarder refused. Paths only;"
            echo "# request bodies are never logged. Permitted inference is not"
            echo "# recorded, and neither is anything your Mac's Ollama does on"
            echo "# its own behalf — a -cloud model's traffic never comes past"
            echo "# here at all."
            echo ""
            cat "$ollama_raw"
        fi

        echo ""
        echo "RAW PROXY MESSAGES"
        echo "------------------"
        echo "# Everything the gatekeeper reported at notice level or above."
        echo "# A few startup lines are normal. Successful connections are absent"
        echo "# by design, not by filtering."
        echo ""
        cat "$raw" 2>/dev/null || echo "  (no output captured)"
    } > "$RUN_LOG"

    # Tell the user what happened, so a blocked host is noticed now rather than
    # next week.
    echo ""
    if [[ -s "$blocked" ]]; then
        echo "Blocked connection attempts this run:"
        sed 's/^/  /' "$blocked"
        echo ""
        echo "To allow one of these permanently, add an anchored pattern to:"
        echo "  $ALLOWLIST_TOOL          (only safer-$TOOL)"
        echo "  $ALLOWLIST_COMMON  (all three commands)"
        echo "or try it for a single run with:  safer-$TOOL --allow HOST"
    else
        echo "No blocked connections this run."
    fi

    # A refused model-management request deserves attention now, not next week.
    if [[ -s "$ollama_raw" ]]; then
        echo ""
        echo "The Ollama forwarder refused $(wc -l < "$ollama_raw" | tr -d ' ') request(s)."
        echo "These are model downloads, uploads or deletions — not inference."
        echo "Read the REFUSED OLLAMA REQUESTS section of the log."
    fi

    echo "Log: $RUN_LOG"

    prune_logs
}

# ---------------------------------------------------------------------------
#  Keep the newest $LOG_KEEP log files FOR THIS TOOL and delete the rest.
#
#  Per tool, not overall: a busy week of one command must not delete the
#  history of another. The grep is what limits it to this tool's files.
#
#  ls -1t lists newest first, one per line. `tail -n +N` prints from line N
#  onward, so this yields everything past the limit.
# ---------------------------------------------------------------------------
prune_logs() {
    local old

    while IFS= read -r old; do
        [[ -n "$old" ]] && rm -f "$LOG_DIR/$old"
    done < <(ls -1t "$LOG_DIR" 2>/dev/null \
             | grep -E "^$TOOL-.*\.log$" \
             | tail -n "+$((LOG_KEEP + 1))")
}


# =============================================================================
#  SECTION 11 — Reading the command line
#
#  Each command has its own argument loop, because each accepts different flags:
#  --effort is claude-only, --ollama is opencode-only. The flags they SHARE are
#  handled here.
#
#  How a command uses it: try its own flags first, then hand anything else to
#  parse_common_arg, then shift by however many arguments that consumed.
#
#      while [[ $# -gt 0 ]]; do
#          case "$1" in
#              --my-own-flag) ...; shift ;;
#              *) parse_common_arg "$@"; shift "$ARGS_CONSUMED" ;;
#          esac
#      done
#
#  ARGS_CONSUMED is how the function reports back — Bash functions can only
#  return a number between 0 and 255, which is not enough.
# =============================================================================

parse_common_arg() {
    case "$1" in
        # Mount a folder READ-ONLY. --add and --ro are the same thing: --add
        # is what you reach for, --ro is there because it says what it does,
        # and because it is what the older scripts and the notes use.
        --add|--ro)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a PATH argument" >&2
                exit 1
            fi
            add_mount ro "$2"
            ARGS_CONSUMED=2
            ;;

        # Mount a folder READ-WRITE. The agent can change your Mac through it,
        # so it is a separate flag rather than the default.
        --rw)
            if [[ $# -lt 2 ]]; then
                echo "Error: --rw requires a PATH argument" >&2
                exit 1
            fi
            add_mount rw "$2"
            ARGS_CONSUMED=2
            ;;

        --allow)
            if [[ $# -lt 2 ]]; then
                echo "Error: --allow requires a HOST argument" >&2
                exit 1
            fi
            EXTRA_ALLOW+=("$2")
            ARGS_CONSUMED=2
            ;;

        --offline)
            OFFLINE=1
            ARGS_CONSUMED=1
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        --)
            # Everything after -- is a command to run instead of the agent.
            if [[ ${#TOOL_ARGS[@]} -gt 0 ]]; then
                echo "Error: cannot mix tool arguments (${TOOL_ARGS[*]}) with '-- COMMAND'" >&2
                exit 1
            fi
            shift                       # drop the -- itself
            COMMAND_ARGS=("$@")
            # Consume everything, so the caller's loop ends.
            ARGS_CONSUMED=$(( $# + 1 ))
            ;;

        *)
            # Anything else is passed through to the agent itself.
            TOOL_ARGS+=("$1")
            ARGS_CONSUMED=1
            ;;
    esac
}

# ---------------------------------------------------------------------------
#  Work out what to run inside the container: the command given after --, or
#  the tool itself with any loose arguments appended.
# ---------------------------------------------------------------------------
safer_resolve_command() {
    if [[ ${#COMMAND_ARGS[@]} -eq 0 ]]; then
        COMMAND_ARGS=("${DEFAULT_COMMAND[@]}" ${TOOL_ARGS+"${TOOL_ARGS[@]}"})
    fi
}


# =============================================================================
#  SECTION 12 — The working directory
# =============================================================================

safer_check_workdir() {
    HOST_PATH="$(pwd -P)"            # -P resolves symlinks
    CONTAINER_PATH="$HOST_PATH"      # same path inside the container

    check_mount_path "$HOST_PATH"

    # -----------------------------------------------------------------------
    #  Refuse to run from inside this script's own folder.
    #
    #  The current directory is always mounted read-write. If you ran a command
    #  from here, the agent could edit an allowlist to grant itself
    #  destinations, or delete connection_logs/ to hide what it tried.
    # -----------------------------------------------------------------------
    if [[ "$HOST_PATH" == "$SAFER_ROOT" || "$HOST_PATH" == "$SAFER_ROOT"/* ]]; then
        echo "Error: refusing to run with the working directory inside $SAFER_ROOT" >&2
        echo "That folder holds the allowlists and the connection logs, and the working" >&2
        echo "directory is mounted read-write. Run this from your project instead." >&2
        exit 1
    fi
}


# =============================================================================
#  SECTION 13 — Make sure the agent image exists and is up to date
#
#  Two things can make an image stale, and both must trigger a rebuild:
#
#    1. The tool was updated on your Mac, so the container's copy is older.
#    2. The Dockerfile was edited, so the image no longer matches the recipe.
#
#  A version check alone catches only the first, and the gap is a trap: a
#  security measure added to a Dockerfile — purging git, say — would do nothing
#  at all until the tool happened to release a new version. So the Dockerfile's
#  checksum is recorded in the image as a label and compared too.
# =============================================================================

# ---------------------------------------------------------------------------
#  Checksum of one file, as a plain hex string.
#
#  macOS ships `shasum` and most Linux systems ship `sha256sum`, and neither is
#  guaranteed, so try both. `awk '{print $1}'` drops the filename that both
#  print after the digest.
# ---------------------------------------------------------------------------
file_checksum() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        # No checksum tool: say so rather than silently returning nothing,
        # which would compare equal to an image built the same way and so
        # disable the check without telling anyone.
        echo "unavailable"
    fi
}

safer_ensure_agent_image() {
    local host_version image_version dockerfile_sum image_sum reason=""

    if [[ ! -f "$DOCKERFILE" ]]; then
        echo "Error: Dockerfile not found: $DOCKERFILE" >&2
        exit 1
    fi

    # -----------------------------------------------------------------------
    #  Which version is installed on your Mac.
    #
    #  The grep pulls the first thing that looks like a version number out of
    #  whatever the tool prints.
    # -----------------------------------------------------------------------
    if ! host_version="$("${VERSION_COMMAND[@]}" 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1)"; then
        host_version=""
    fi

    if [[ -z "$host_version" ]]; then
        echo "Error: could not determine the installed version of $TOOL on this Mac." >&2
        echo "Is it installed, and does '${VERSION_COMMAND[*]}' print a version?" >&2
        exit 1
    fi

    dockerfile_sum="$(file_checksum "$DOCKERFILE")"

    # -----------------------------------------------------------------------
    #  What is in the image already.
    #
    #  The `docker image inspect` check first is important. Without it, `docker
    #  run` on a missing image makes Docker try to DOWNLOAD it from Docker Hub
    #  and then run it. These are unclaimed public names, so anyone could
    #  publish one, and it would start with all of your folders mounted.
    #
    #  So: if the image is not here, build it. Never fetch it.
    # -----------------------------------------------------------------------
    image_version=""
    image_sum=""
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        image_version="$(
            docker run --rm --pull=never "$IMAGE" "${VERSION_COMMAND[@]}" 2>/dev/null \
            | grep -Eo '[0-9]+(\.[0-9]+)+' \
            | head -1 || true
        )"
        # The label is written by the build below. An image built before this
        # check existed has no such label, so it reads as empty and rebuilds
        # once — which is the right outcome, since there is no way to know what
        # recipe it came from.
        image_sum="$(
            docker image inspect \
                --format '{{index .Config.Labels "safer.dockerfile-sha256"}}' \
                "$IMAGE" 2>/dev/null || true
        )"
    fi

    if [[ -z "$image_version" ]]; then
        reason="new"
    elif [[ "$host_version" != "$image_version" ]]; then
        reason="$image_version -> $host_version"
    elif [[ "$dockerfile_sum" != "$image_sum" ]]; then
        reason="$(basename "$DOCKERFILE") changed"
    fi

    if [[ -n "$reason" ]]; then
        if [[ "$reason" == "new" ]]; then
            echo "Building $IMAGE ($host_version)..."
        else
            echo "Rebuilding $IMAGE ($reason)..."
        fi

        docker build \
            --build-arg "TOOL_VERSION=$host_version" \
            --label "safer.dockerfile-sha256=$dockerfile_sum" \
            -f "$DOCKERFILE" \
            -t "$IMAGE" \
            "$DOCKER_DIR"
    fi
}


# =============================================================================
#  SECTION 14 — Run it
#
#  The flags, in order:
#
#    --rm                     delete the container when it exits
#    -it                      interactive terminal, so the agent's interface
#                             works and Ctrl-C reaches it
#    --read-only              the container's own filesystem cannot be modified.
#                             Only the folders mounted below are writable
#    --tmpfs /tmp             one writable area, in memory, discarded on exit
#    tmpfs on $HOME           and on each folder inside it that holds a config
#                             mount. Also in memory, also discarded. See the
#                             note below
#    --cap-drop ALL           remove every Linux privilege. No raw network
#                             access, no mounting, no changing ownership
#    --security-opt
#      no-new-privileges      and forbid regaining any, which blocks the
#                             setuid tricks that privilege escalation uses
#    --user <you>             run as YOUR user id, so files created in a mounted
#                             folder belong to you rather than to root
#    /etc/passwd, /etc/group  generated per run, so that id has a NAME. See
#                             build_identity_files in section 9
#    --pull=never             never download an image. See section 13
#    --env HOME=...           the tools look for config relative to $HOME
#    --workdir                start in the project folder
#
#  The order of the mount groups does not matter for correctness: Docker sorts
#  them by destination depth, so the .git masks and the dangerous-path covers
#  always land on top of the folders they sit inside.
#
#  ---------------------------------------------------------------------------
#  WHY $HOME IS A TMPFS
#  ---------------------------------------------------------------------------
#  The container filesystem is read-only, and /home/agent is part of it. That
#  folder is not even in the image: Docker creates it because the config mounts
#  below need a parent. So it exists, and nothing can be created beside them.
#
#  Every one of these tools writes somewhere in $HOME that we do not mount.
#  opencode wants $HOME/.local/state, the XDG default for session state, and
#  stops with:
#
#      EROFS: read-only file system, mkdir '/home/agent/.local/state'
#
#  Naming each such folder would be a list that goes stale on the next release.
#  A tmpfs over the whole of $HOME answers all of them at once.
#
#  That tmpfs is only half the job. The other half — covering the root-owned
#  parent folders Docker invents underneath it — is build_home_mounts in
#  section 9. Read the essay above that function; it is the part that is easy
#  to get wrong, and it was got wrong twice.
#
#  This gives away nothing. A tmpfs lives in memory and disappears when the
#  container stops, so anything the agent writes there is thrown away and never
#  reaches your Mac. The agent already runs code inside this container, so a
#  scratch $HOME does not widen that.
#
#  It also does not shadow the config mounts, for the reason in the paragraph
#  above: /home/agent is shallower than /home/agent/.config/opencode, so the
#  real mounts are applied afterwards and land on top of it.
#
#  These use the "--tmpfs dest:options" form and NOT --mount type=tmpfs, which
#  is the opposite of the usual advice. The reason is noexec, and it is recorded
#  on writable_tmpfs_arg in section 9, together with what a running container
#  actually reported.
# =============================================================================

safer_run() {
    build_home_mounts
    build_identity_files

    #  Assembled into an array rather than written straight onto the docker
    #  command line, so that SAFER_DEBUG can print exactly what Docker is
    #  given. A launcher that builds a forty-argument command should be able to
    #  show that command. Guessing at it from the source is how an afternoon
    #  gets lost, and that is not hypothetical: two attempts at making $HOME
    #  writable were spent on a mount nobody could confirm had been passed.
    local DOCKER_ARGS=(
        run --rm -it
        --read-only
        --tmpfs /tmp:rw,exec,mode=1777,size=512m
        ${HOME_MOUNTS+"${HOME_MOUNTS[@]}"}
        --cap-drop ALL
        --security-opt no-new-privileges
        --user "$(id -u):$(id -g)"
        --pull=never
        --env HOME="$CONTAINER_HOME"
        ${IDENTITY_MOUNTS+"${IDENTITY_MOUNTS[@]}"}
        ${TOOL_ENV+"${TOOL_ENV[@]}"}
        ${NET_ARGS+"${NET_ARGS[@]}"}
        ${AUTH_MOUNTS+"${AUTH_MOUNTS[@]}"}
        ${CONFIG_MOUNTS+"${CONFIG_MOUNTS[@]}"}
        ${EXTRA_MOUNTS+"${EXTRA_MOUNTS[@]}"}
        --mount "type=bind,src=$HOST_PATH,dst=$CONTAINER_PATH"
        ${PATH_PINS+"${PATH_PINS[@]}"}
        ${GIT_MASKS+"${GIT_MASKS[@]}"}
        --workdir "$CONTAINER_PATH"
        "$IMAGE"
        "${COMMAND_ARGS[@]}"
    )

    #  SAFER_DEBUG=1 safer-opencode     show the arguments, then run
    #  SAFER_DEBUG=2 safer-opencode     show the arguments and stop
    #
    #  One per line, because the interesting part is always which mounts are
    #  present.
    if [[ -n "${SAFER_DEBUG:-}" ]]; then
        echo "--- docker arguments ---" >&2
        printf '  %s\n' "${DOCKER_ARGS[@]}" >&2
        echo "--- end ---" >&2
        if [[ "$SAFER_DEBUG" == 2 ]]; then
            echo "SAFER_DEBUG=2: stopping without starting the agent." >&2
            return 0
        fi
    fi

    docker "${DOCKER_ARGS[@]}"

    # When this returns, the exit trap in section 3 runs: it saves the
    # gatekeeper's log to connection_logs/, then removes the gatekeeper and the
    # network.
}
