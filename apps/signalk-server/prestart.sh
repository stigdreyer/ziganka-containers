#!/bin/bash
# Signal K Server app-prestart hook (sourced by the generated framework prestart).
# OIDC is declarative now (routing.auth.mode: oidc): the framework provisions the
# client secret, writes the Authelia snippet, and appends SIGNALK_OIDC_CLIENT_SECRET
# /_ISSUER/_REDIRECT_URI to runtime.env. This hook keeps the Signal K-specific
# steps: the security.json bootstrap, external-URL advertising, the Ziganka fork's
# Docker-socket GID resolution, and the InfluxDB logging plugin.
#
# Ziganka fork of halos-marine-containers' signalk-server: dirkwa image, host
# Docker socket mounted into the container, per-host DOCKER_GID, ziganka- paths.
#
# The secret-file handling below (security.json, admin-password, the InfluxDB
# plugin config, the QuestDB history-provider config) is ported from upstream's
# TOCTOU-hardened rewrite (halos-org/halos-marine-containers, ref
# 03c7bd716d148ad40b1fe7f4084b3643179ec2f2). Our default-data/data/settings.json
# never shipped the broken gpsd pipeline upstream's migrate_gpsd_liner repairs,
# so that migration is not ported. Ziganka has no marine-questdb-container app
# (see apps table in CLAUDE.md), so QUESTDB_INSTALLED is always false here —
# configure_questdb never runs, and clear_gone_default_history_provider is
# dead-simple insurance against a stray settings.json key rather than an active
# cleanup path. Ported anyway so a QuestDB app, if ever added, needs no prestart
# change to be picked up.

SIGNALK_DATA="${CONTAINER_DATA_ROOT}/data"
SECURITY_FILE="${SIGNALK_DATA}/security.json"
PLUGIN_CONFIG_DIR="${SIGNALK_DATA}/plugin-config-data"
PLUGIN_CONFIG="${PLUGIN_CONFIG_DIR}/signalk-to-influxdb2.json"

# Create data directory if needed
mkdir -p "${SIGNALK_DATA}"

# --- refresh the rolling image tag (best-effort, network-dependent) --------
# The Ziganka fork tracks dirkwa's ":dirkwa" tag (or whatever SIGNALK_IMAGE is
# set to), which moves forward on every upstream rebuild without the tag
# itself changing. `docker compose up`'s default pull policy only pulls an
# image that is missing locally, so once a rolling tag has been pulled once it
# is never re-checked against the registry -- the container keeps running the
# same digest indefinitely even as the tag advances upstream (this is why
# `apt upgrade`, which only updates this package's definition files, does not
# by itself move Signal K to a newer version). Pulling here, before compose
# starts, is what makes the rolling tag actually roll. Best-effort and
# time-boxed: on a boat with no signal this must not delay or fail the boot,
# so compose falls back to whatever is already cached.
SIGNALK_IMAGE="${SIGNALK_IMAGE:-ghcr.io/dirkwa/signalk-server:dirkwa}"
if timeout 120 docker pull "${SIGNALK_IMAGE}" >/dev/null 2>&1; then
    echo "Pulled latest ${SIGNALK_IMAGE}"
else
    echo "WARNING: could not pull ${SIGNALK_IMAGE} (no internet?); using the cached image"
fi

# --- InfluxDB plugin install (best-effort, network-dependent) --------------
# The Ziganka fork tracks dirkwa's image, which does not bake the curated
# plugin set in (unlike upstream's ghcr.io/halos-org/signalk-server-docker).
# Install it here if missing; the hardened config write happens below in the
# python block regardless of whether install succeeded, so a retry lands the
# config as soon as a later boot manages to install the plugin.
INFLUXDB_ENV="/etc/container-apps/marine-influxdb-container/env"
INFLUXDB_ADMIN_TOKEN=""
if [ -f "${INFLUXDB_ENV}" ]; then
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)
fi

# The compose file, not the env file. `apt remove` leaves a package in
# `deinstall ok config-files`: /etc/container-apps/marine-questdb-container/env
# and the systemd unit both survive, and only `apt purge` takes them. The
# compose file is payload and goes on either. Gating on env made "the app is
# gone" false for the ordinary uninstall, which left settings.json naming a
# provider that can never register -- and that is a standing warn notification,
# not a quiet fallback. Verified on a device (upstream).
#
# No marine-questdb-container app exists in this store yet, so this is always
# empty on Ziganka -- see the file header.
QUESTDB_COMPOSE="/var/lib/container-apps/marine-questdb-container/docker-compose.yml"
QUESTDB_INSTALLED=""
if [ -f "${QUESTDB_COMPOSE}" ]; then
    QUESTDB_INSTALLED=1
fi

if [ -n "${INFLUXDB_ADMIN_TOKEN}" ] && [ ! -d "${SIGNALK_DATA}/node_modules/signalk-to-influxdb2" ]; then
    echo "Installing signalk-to-influxdb2 plugin (image: ${SIGNALK_IMAGE})..."
    if timeout 120 docker run --rm --entrypoint npm \
        -v "${SIGNALK_DATA}:/home/node/.signalk" \
        -u 1000:1000 \
        "${SIGNALK_IMAGE}" \
        install --prefix /home/node/.signalk signalk-to-influxdb2; then
        echo "Plugin installed successfully"
    else
        echo "WARNING: Failed to install signalk-to-influxdb2 (no internet?). Will retry on next restart."
    fi
fi

# --- secret files -----------------------------------------------------------
# security.json (admin hash + JWT signing key) and the InfluxDB token config are
# written by root into a directory this hook hands to uid 1000, so the container
# -- and any host process running as pi, the same uid -- can put something else
# at those names first.
#
# All of it happens in one python3 block, because the shell cannot express the
# constraints:
#
#   * chmod(2) always dereferences and has no --no-dereference, so converging a
#     mode is only safe as open(O_NOFOLLOW) + fchmod.
#   * `set -o noclobber` is NOT O_EXCL. Bash stats the path first and adds
#     O_EXCL only when that stat fails, so a symlink to a FIFO or a device node
#     is followed.
#   * Guarding named paths cannot cover a swapped *parent*, because every
#     syscall re-resolves the whole path. The parents are opened once here and
#     everything is *at-relative to those descriptors.
#   * The predicate is the file type, not "is a symlink": a directory, FIFO,
#     socket or device at one of these names has to be handled too.
#   * O_NOFOLLOW refuses a symlink but not a FIFO, and opening a FIFO to read
#     blocks until a writer appears -- for root as much as anyone. Reads add
#     O_NONBLOCK and check the type through the descriptor.
#
# Refusing to start is the answer when security.json cannot be made safe: an
# open Signal K is worse than an absent one. That licence is narrow. An abort
# the container can trigger on demand, or one caused by a fault that redirects
# nothing, is a permanent outage bought for nothing -- ExecStartPre gets five
# restarts before systemd stops trying.
#
# The token is read before the block so python needs no shell interpolation.
HALOS_DATA_ROOT="${CONTAINER_DATA_ROOT}" \
HALOS_SK_DATA="${SIGNALK_DATA}" \
HALOS_INFLUX_TOKEN="${INFLUXDB_ADMIN_TOKEN}" \
HALOS_QUESTDB_INSTALLED="${QUESTDB_INSTALLED}" \
python3 -P - <<'HALOS_SECRETS_PY'
import errno, json, os, secrets, stat, sys

DATA_ROOT = os.environ["HALOS_DATA_ROOT"]
SK_DATA = os.environ["HALOS_SK_DATA"]
INFLUX_TOKEN = os.environ.get("HALOS_INFLUX_TOKEN") or ""
QUESTDB_INSTALLED = bool(os.environ.get("HALOS_QUESTDB_INSTALLED"))

# A racer that wins once will usually lose the next attempt; one that wins every
# attempt is not a race we can outlast, and refusing to start is then correct.
ATTEMPTS = 4

# Declared in the plugin's own code, not derived from its package name, and it is
# the key the history provider registry and settings.json both index by.
QUESTDB_PLUGIN_ID = "signalk-questdb-history-provider"


def warn(msg):
    print("WARNING: " + msg, flush=True)


def open_dir(path, parent_fd=None):
    """Pin a directory by descriptor.

    Everything below is *at-relative to this fd, so the parent cannot be swapped
    between one syscall and the next -- the gap no per-path check can close,
    because each syscall otherwise re-resolves the whole path.
    """
    return os.open(
        path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd
    )


def open_regular(dfd, name):
    """Open an existing regular file for reading, without following or blocking.

    O_NOFOLLOW refuses a symlink but not a FIFO, and a FIFO opened for reading
    blocks until a writer appears. The type has to be checked through the
    descriptor: checking the name first would be a different object by the time
    the open ran.
    """
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(errno.EINVAL, "not a regular file", name)
    return fd


def move_aside(dfd, name):
    """Rename a wrong-type directory out of the way, to a name that is free.

    A fixed destination is not free: occupying it makes every rename fail, and
    aborting on that hands anyone who can write here a permanent boot wedge. A
    run that already moved one aside collides with its own leftover the same way.
    """
    for suffix in [".unexpected"] + [
        ".unexpected.%s" % secrets.token_hex(4) for _ in range(ATTEMPTS)
    ]:
        try:
            os.rename(name, name + suffix, src_dir_fd=dfd, dst_dir_fd=dfd)
        except FileNotFoundError:
            return True
        except OSError:
            continue
        warn("moved aside to %s%s; its contents are intact" % (name, suffix))
        return True
    warn("could not move %s aside; every candidate name is taken" % name)
    return False


def clear_unexpected(dfd, name, want_dir=False):
    """Make `name` absent or the type we need, without following anything.

    Returns True when the name is now safe to create at -- absent, or already the
    wanted type -- and False only when something is still in the way.

    Root creates only a regular file (or, for the config dir, a directory) at
    these names, so anything else is tampering or wreckage. A wrong-type
    directory is renamed rather than deleted: it may hold an operator's data.
    """
    try:
        st = os.lstat(name, dir_fd=dfd)
    except FileNotFoundError:
        return True

    if stat.S_ISDIR(st.st_mode) if want_dir else stat.S_ISREG(st.st_mode):
        return True

    kind = "directory" if stat.S_ISDIR(st.st_mode) else (
        "symlink" if stat.S_ISLNK(st.st_mode) else "non-regular file"
    )
    warn("unexpected %s at %s; clearing it" % (kind, name))
    if stat.S_ISDIR(st.st_mode):
        return move_aside(dfd, name)
    try:
        os.unlink(name, dir_fd=dfd)
    except FileNotFoundError:
        pass  # someone else removed it; absent is the state we wanted
    except OSError as exc:
        warn("could not clear %s: %s" % (name, exc))
        return False
    return True


def create_exclusive(dfd, name, content, mode=0o600):
    """Create and fill `name`, refusing to follow anything.

    O_EXCL|O_NOFOLLOW is a real kernel exclusive create. Bash's `noclobber` is
    not equivalent: it stats first and only adds O_EXCL when that stat fails, so
    a symlink to a FIFO or a device is followed.
    """
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        mode,
        dir_fd=dfd,
    )
    try:
        os.fchmod(fd, mode)  # explicit: the mode above is masked by umask
    except BaseException:
        os.close(fd)
        raise
    # UTF-8 explicitly: every caller writes JSON, and text mode would otherwise
    # encode it in the process locale.
    with os.fdopen(fd, "w", encoding="utf-8") as f:  # owns fd, including on failure
        f.write(content)


def create_guarded(dfd, name, content, replace=False, mode=0o600):
    """Clear the name and create it, conceding only after losing repeatedly.

    O_EXCL turns a lost race into EEXIST instead of a write through whatever was
    planted, which is the point. Treating that EEXIST as fatal would hand the
    same racer an ExecStartPre failure on demand, so the loss costs a retry.

    `replace` is for a name this hook owns and rewrites rather than creates once:
    a regenerated secret, whose old file no longer opens anything, and the temp
    files the atomic writes stage through. Without it the O_EXCL create fails
    against the hook's own last run -- and `clear_unexpected` will not remove the
    leftover, because a regular file is exactly the type it wants there.
    """
    for _ in range(ATTEMPTS):
        if not clear_unexpected(dfd, name):
            return False
        if replace:
            try:
                os.unlink(name, dir_fd=dfd)
            except FileNotFoundError:
                pass
            except OSError as exc:
                warn("could not replace %s: %s" % (name, exc))
                return False
        try:
            create_exclusive(dfd, name, content, mode)
            return True
        except FileExistsError:
            warn("%s reappeared between the clear and the create; retrying" % name)
    return False


def converge_mode(dfd, name):
    """Restrict an existing file without re-resolving its path.

    Failing to tighten a mode warrants a warning, never a refusal to boot: on a
    read-only filesystem, which is how a worn SD card fails, nothing can be
    redirected anywhere either.
    """
    try:
        fd = open_regular(dfd, name)
    except FileNotFoundError:
        return
    except OSError as exc:
        warn("could not open %s to check its mode: %s" % (name, exc))
        return
    try:
        os.fchmod(fd, 0o600)
    except OSError as exc:
        warn("could not tighten the mode on %s: %s" % (name, exc))
    finally:
        os.close(fd)


def read_settings(sk_fd):
    """Parse settings.json into (settings, mode, original), None when absent.

    Both writers below need the same three things, and each of them is a way to
    corrupt a value neither writer was asked to touch. The mode is the permission
    bits uid 1000 chose, kept because root recreates the file. UTF-8 is explicit
    because settings.json is UTF-8 by specification while text mode would decode
    it in the process locale -- under a single-byte locale a vessel name comes
    back as two characters that json.dumps then re-escapes.
    """
    try:
        fd = open_regular(sk_fd, "settings.json")
    except FileNotFoundError:
        return None  # a fresh install has none until the postinst seeds default-data

    with os.fdopen(fd, encoding="utf-8") as f:  # owns fd from here
        # Permission bits only. S_IMODE keeps setuid and setgid as well -- root
        # would otherwise reproduce them on a file it creates here.
        mode = stat.S_IMODE(os.fstat(f.fileno()).st_mode) & 0o777
        original = f.read()

    settings = json.loads(original)
    if not isinstance(settings, dict):
        raise ValueError(
            "settings.json is a %s, not an object" % type(settings).__name__
        )
    return settings, mode, original


def write_settings(sk_fd, settings, mode):
    """Replace settings.json atomically. False when the staged write failed."""
    # Not settings.json.tmp: that is the name the server's own atomic write stages
    # through, so a leftover there is a root-owned file in its way and its next
    # save fails EACCES.
    tmp = "settings.json.halos-tmp"
    body = json.dumps(settings, indent=2) + "\n"
    if not create_guarded(sk_fd, tmp, body, replace=True, mode=mode):
        return False
    # renameat replaces the name and never follows it, so a symlink swapped in
    # after the read above is overwritten rather than written through.
    os.replace(tmp, "settings.json", src_dir_fd=sk_fd, dst_dir_fd=sk_fd)
    return True


def open_plugin_config_dir(sk_fd):
    """Descriptor for plugin-config-data, or None when it cannot be made safe.

    Both plugin configs (InfluxDB, QuestDB) land here, in a directory uid 1000
    owns, so the type check and the mkdir live in one place. Two copies of this
    could drift, and the half that drifted would write a config through
    whatever was planted at that name.
    """
    if not clear_unexpected(sk_fd, "plugin-config-data", want_dir=True):
        warn("cannot make plugin-config-data safe to write; skipping")
        return None
    try:
        os.mkdir("plugin-config-data", 0o755, dir_fd=sk_fd)
    except FileExistsError:
        pass
    return open_dir("plugin-config-data", parent_fd=sk_fd)


def configure_questdb(sk_fd):
    """Point the history provider at the QuestDB app. Never fatal.

    Written once and then left alone, unlike the InfluxDB config below. That one
    is rewritten every boot because a rotating token has to reach it; this one
    carries no secret, so a rewrite could only ever discard what the operator
    changed -- path filters, sampling rates, retention.

    Host and ports are written explicitly even though they are the plugin's
    defaults. A rebase onto a new upstream may move those defaults, and a
    device's configuration should not follow silently.

    Dead on Ziganka today -- there is no marine-questdb-container app in this
    store, so QUESTDB_INSTALLED is always false and this never runs. Ported so
    adding that app later needs no prestart change.
    """
    cfg_fd = open_plugin_config_dir(sk_fd)
    if cfg_fd is None:
        return
    try:
        name = QUESTDB_PLUGIN_ID + ".json"
        if not clear_unexpected(cfg_fd, name):
            warn("cannot make %s safe to write; skipping" % name)
            return

        converge_mode(cfg_fd, name)
        try:
            fd = open_regular(cfg_fd, name)
        except FileNotFoundError:
            pass
        else:
            os.close(fd)
            return

        if create_guarded(cfg_fd, name, json.dumps({
            "enabled": True,
            "configuration": {
                "questdbHost": "127.0.0.1",
                "questdbHttpPort": 9000,
                "questdbIlpPort": 9009,
            },
        }, indent=2) + "\n"):
            print("QuestDB history provider configured")
    finally:
        os.close(cfg_fd)


def clear_gone_default_history_provider(sk_fd, installed):
    """Drop settings.json's default history provider when its app is gone.

    Only that. Installing the QuestDB app does not make it the default, because
    naming it would take the slot from whatever is already serving history on
    that device -- and on a device that has run InfluxDB since before QuestDB
    existed, the key is absent not because nobody chose but because there was
    never anything to choose between. The operator picks, in the admin UI under
    Apps & Plugins -> Configuration, and Signal K records the first provider to
    register on a device that has never had one (SignalK/signalk-server#2981).

    A key naming a gone provider is a standing alarm rather than a fallback: the
    first history request after the app is removed raises a warn notification at
    notifications.server.history.defaultProvider ("Configured default history
    provider ... is not available"), and the server clears it only when that
    provider registers again, which for an uninstalled app is never. Verified on
    a device (upstream). Hence this one direction.

    Exact match only. Any other value is the operator's, and the only value this
    removes is one naming the app that just went away.

    Always called with installed=False on Ziganka (no QuestDB app exists here),
    so this only ever matters if a settings.json carried over from a device that
    once had upstream's QuestDB app names it as the default.
    """
    if installed:
        return
    read = read_settings(sk_fd)
    if read is None:
        return
    settings, mode, _ = read

    history = settings.get("historyApi")
    if not isinstance(history, dict):
        # Absent, or malformed and not root's to interpret.
        return

    if history.get("defaultProvider") != QUESTDB_PLUGIN_ID:
        return
    del history["defaultProvider"]

    settings["historyApi"] = history
    if write_settings(sk_fd, settings, mode):
        print("QuestDB is gone; cleared it as the default history provider")
    else:
        warn("could not clear the default history provider")


def configure_influx(sk_fd, token):
    """Point the logging plugin at InfluxDB. Never fatal; see the call site.

    Writes/updates config only -- installing the plugin itself (docker run npm
    install) happens in bash before this python block runs, since the Ziganka
    fork's dirkwa image does not bake the plugin in.
    """
    cfg_fd = open_plugin_config_dir(sk_fd)
    if cfg_fd is None:
        return
    try:
        name = "signalk-to-influxdb2.json"
        if not clear_unexpected(cfg_fd, name):
            warn("cannot make %s safe to write; skipping" % name)
            return

        converge_mode(cfg_fd, name)
        try:
            fd = open_regular(cfg_fd, name)
        except FileNotFoundError:
            if create_guarded(cfg_fd, name, json.dumps({
                "enabled": True,
                "configuration": {"influxes": [{
                    "url": "http://localhost:8086",
                    "token": token,
                    "org": "marine",
                    "bucket": "marine",
                    "onlySelf": True,
                    "resolution": 1000,
                }]},
            }, indent=2) + "\n"):
                print("InfluxDB plugin configured")
            return

        # Read through the descriptor, not the path: json.load on a re-planted
        # symlink would copy a root-only file out, and os.replace would then
        # leave it here owned by uid 1000.
        with os.fdopen(fd) as f:
            cfg = json.load(f)
        if not isinstance(cfg, dict):
            raise ValueError("config is a %s, not an object" % type(cfg).__name__)
        influxes = cfg.get("configuration", {}).get("influxes", [])
        if influxes:
            influxes[0]["token"] = token

        # `replace` because this name is one the hook owns and rewrites: without
        # it, a .tmp left by an interrupted run survives clear_unexpected (a
        # regular file is the wanted type) and every later O_EXCL create fails
        # EEXIST, so the token is never refreshed again on that device.
        tmp = name + ".tmp"
        if not create_guarded(cfg_fd, tmp, json.dumps(cfg, indent=2) + "\n",
                              replace=True):
            warn("cannot write %s; leaving the config alone" % tmp)
            return
        os.replace(tmp, name, src_dir_fd=cfg_fd, dst_dir_fd=cfg_fd)
        print("InfluxDB plugin token updated")
    finally:
        os.close(cfg_fd)


sk_fd = open_dir(SK_DATA)
root_fd = open_dir(DATA_ROOT)

if not clear_unexpected(sk_fd, "security.json"):
    sys.exit("ERROR: cannot make security.json safe to write; refusing to start")

converge_mode(sk_fd, "security.json")

# A regular file here means an existing install. Testing only for existence
# would accept whatever a racer left after the clear above -- a FIFO at this name
# is not a security configuration, and skipping the create branch on account of
# it starts Signal K with none.
try:
    existing = stat.S_ISREG(os.lstat("security.json", dir_fd=sk_fd).st_mode)
except FileNotFoundError:
    existing = False

if not existing:
    import bcrypt  # only a new install hashes anything

    print("Creating initial security.json with default admin user...")
    password = secrets.token_hex(16)

    # admin-password goes first. It is emergency access when OIDC is what broke,
    # and it exists only in memory until it lands -- writing security.json first
    # and failing here would make every later boot skip this branch, losing the
    # password for the life of the device. Its parent is root-owned and outside
    # the bind mount, but it is created the same way so the rule holds by
    # construction rather than by luck.
    if not create_guarded(root_fd, "admin-password", password + "\n", replace=True):
        sys.exit("ERROR: cannot write the emergency admin password; refusing to start")

    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    if not create_guarded(sk_fd, "security.json", json.dumps({
        "strategy": "./tokensecurity",
        "users": [{"username": "admin", "type": "admin", "password": hashed}],
        "allow_readonly": True,
        "secretKey": secrets.token_hex(32),
    }, indent=2) + "\n"):
        sys.exit("ERROR: cannot make security.json safe to write; refusing to start")

    print("Security initialized with admin user.")
    print("NOTE: Local admin password stored in %s/admin-password" % DATA_ROOT)
    print("This is a fallback for emergency access. Use OIDC for regular login.")

# Logging is not navigation: a failure here must not cost the boot.
if INFLUX_TOKEN:
    try:
        configure_influx(sk_fd, INFLUX_TOKEN)
    except Exception as exc:
        warn("InfluxDB plugin config not updated: %s" % exc)

if QUESTDB_INSTALLED:
    try:
        configure_questdb(sk_fd)
    except Exception as exc:
        warn("QuestDB plugin config not written: %s" % exc)

# Unconditional, unlike the plugin config above: this runs to clear the key on
# a device the app was removed from, which is a state only reachable with
# QUESTDB_INSTALLED false. Separate from the config for the rest -- they fail
# for different reasons, and history still works when only a stale key remains.
try:
    clear_gone_default_history_provider(sk_fd, QUESTDB_INSTALLED)
except Exception as exc:
    warn("default history provider not cleared: %s" % exc)

os.close(sk_fd)
os.close(root_fd)
HALOS_SECRETS_PY

# Resolve the host's Docker socket group GID so the container's group_add works
# on any boat, not just ones where the docker group happens to be a fixed number.
# Reading the GID off the socket is more robust than `getent group docker`
# (handles a differently-named owning group). Consumed by docker-compose.yml
# group_add — appended to the framework-owned runtime.env below.
DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
if [ -z "${DOCKER_GID}" ]; then
    DOCKER_GID="$(getent group docker | cut -d: -f3)"
fi

# Signal K advertises its external URL via mDNS from these. EXTERNALHOST strips
# the .local suffix that Signal K's dnssd library re-appends; the external port
# comes from the routing registry, defaulting to the HTTPS port. Appended to the
# framework-owned runtime.env (the OIDC vars are written there by the framework).
EXTERNAL_PORT="$(grep '^signalk-server=' /etc/halos/port-registry 2>/dev/null | cut -d= -f2)"
{
    echo "EXTERNALHOST=${HALOS_DOMAIN%.local}"
    echo "EXTERNALPORT=${EXTERNAL_PORT:-443}"
    # Requires upstream EXTERNALSSL support: https://github.com/SignalK/signalk-server/pull/2484
    echo "EXTERNALSSL=1"
    # Docker socket group GID, resolved above — consumed by docker-compose.yml group_add
    echo "DOCKER_GID=${DOCKER_GID}"
} >> "$RUNTIME_ENV"

# The container runs as node:node while this script runs as root, so what root
# creates here has to be handed over. Named paths only: a recursive chown of the
# data root walks the whole plugin tree (and, on this fork, the InfluxDB plugin
# installed via `docker run` above) on every boot.
# -h throughout: these live in a directory the container can write, so following
# a symlink would let it choose which host path root hands over.
#
# Each of these tests a path and then chowns it as a separate command, in a
# directory the container owns. Removing the file in between makes chown exit
# non-zero, and under the framework's set -e that is an ExecStartPre failure --
# so a vanished path warns rather than taking the navigation server down. A path
# that is gone needs no chown.
hand_over() {  # $1 = path, $2... = extra chown flags
    local path="$1"; shift
    chown -h "$@" 1000:1000 "${path}" ||
        echo "WARNING: could not hand ${path} to the container"
}

hand_over "${SIGNALK_DATA}"
# Unconditional, not inside a create branch: the python block above may have
# created security.json on this run or on any earlier one, and the container
# cannot log anyone in through a file it does not own.
if [ -f "${SECURITY_FILE}" ]; then
    hand_over "${SECURITY_FILE}"
fi
if [ -f "${SIGNALK_DATA}/settings.json" ]; then
    hand_over "${SIGNALK_DATA}/settings.json"
fi

# The app store installs plugin updates into this tree as uid 1000, and that is
# the only route by which the InfluxDB plugin (or any other) stays updatable.
# Non-recursive on purpose: what is already inside belongs to the container.
#
# The dangling-symlink case has to be cleared first, and the framework prestart
# is why: it runs under set -e and sources this hook as a statement, so any
# non-zero status here fails ExecStartPre and the server never starts. mkdir -p
# does not create through a dangling symlink -- it exits 1 -- and uid 1000 owns
# this directory, so leaving one there would wedge the unit on every boot with
# nothing to clear it. A symlink to a directory that exists is left alone: that
# is someone relocating the plugin tree to another disk, mkdir -p accepts it,
# and chown -h then touches the link rather than whatever it points at.
if [ -L "${SIGNALK_DATA}/node_modules" ] && [ ! -e "${SIGNALK_DATA}/node_modules" ]; then
    rm -f "${SIGNALK_DATA}/node_modules"
fi
# The chown belongs inside the success branch. Tolerating the mkdir and then
# chowning unconditionally would trade one abort for another -- chown on a path
# that does not exist is itself non-zero -- turning "the server runs, plugin
# updates are broken" back into "the server never starts".
if mkdir -p "${SIGNALK_DATA}/node_modules"; then
    hand_over "${SIGNALK_DATA}/node_modules"
else
    echo "WARNING: could not create ${SIGNALK_DATA}/node_modules; plugin updates will fail"
fi
if [ -f "${SIGNALK_DATA}/package.json" ]; then
    hand_over "${SIGNALK_DATA}/package.json"
fi
if [ -d "${PLUGIN_CONFIG_DIR}" ]; then
    hand_over "${PLUGIN_CONFIG_DIR}" -R
fi
