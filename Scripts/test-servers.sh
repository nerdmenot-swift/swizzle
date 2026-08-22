#!/usr/bin/env bash
# Manage the integration-test MariaDB servers.
#
#   ./Scripts/test-servers.sh up      download (cached), init, start, seed, wait
#   ./Scripts/test-servers.sh down    stop every server, keep data
#   ./Scripts/test-servers.sh reset   wipe data directories and rebuild
#   ./Scripts/test-servers.sh status  show what is listening
#   ./Scripts/test-servers.sh clean   also remove downloaded binaries
#
# Native binaries, no Docker and no VM. Servers are defined in
# testservers/servers.conf; everything lands under .testservers/ (gitignored).
#
# Integration tests skip cleanly when these aren't running, so `swift test`
# stays green without them.

set -uo pipefail
cd "$(dirname "$0")/.."

# `SWIZZLE_TESTSERVERS_ROOT` moves everything off the checkout.
#
# Needed wherever the checkout is not a normal local filesystem. Running this
# inside a container with the project bind-mounted from macOS, `mariadb-install-db`
# fails against the mounted path and succeeds immediately against container-local
# storage — the same binary, the same flags, only the filesystem differs. CI wants
# the same escape hatch for the same reason.
ROOT="${SWIZZLE_TESTSERVERS_ROOT:-$PWD/.testservers}"
# Binaries and data directories are keyed by **platform**, because a checkout is
# routinely used from more than one at once: `Scripts/linux-tests.sh` mounts this
# directory into a Linux container on a macOS host, and CI may do the same.
#
# Without the suffix the cache is "is the directory there", so the container
# found the host's arm64-darwin `mariadbd` and died with
# `cannot execute binary file: Exec format error` — a message that says nothing
# about why. Data directories are keyed too: an initialised MySQL datadir is not
# portable between platforms either.
PLATFORM_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
DIST="$ROOT/dist-$PLATFORM_TAG"
DATA="$ROOT/data-$PLATFORM_TAG"
RUN="$ROOT/run-$PLATFORM_TAG"
CONF="testservers/servers.conf"
INDEX_URL="https://github.com/doze-dev/doze-binaries/releases/download/mariadb/index.yaml"
INDEX="$DIST/index.yaml"

mkdir -p "$DIST" "$DATA" "$RUN"

# Unix sockets must live somewhere short: macOS caps the path at 103 bytes, and
# a socket inside the project directory blows past that with no obvious cause —
# the server just logs "socket file path is too long" and aborts.
socket_for() { echo "/tmp/swzl-$1.sock"; }

# MariaDB and MySQL refuse to run as root unless told to, and a CI container is
# root by default:
#
#     Please consult the Knowledge Base to find out how to run mysqld as root!
#
# Empty for a normal developer account, so nothing changes there.
root_user_flag=()
if [[ "$(id -u)" -eq 0 ]]; then
  root_user_flag=(--user=root)
fi

platform() {
  local arch; arch="$(uname -m)"
  case "$(uname -s)" in
    Darwin) [[ "$arch" == "arm64" ]] && echo "aarch64-apple-darwin" || echo "x86_64-apple-darwin" ;;
    Linux)  [[ "$arch" == "aarch64" ]] && echo "aarch64-unknown-linux-gnu" || echo "x86_64-unknown-linux-gnu" ;;
    *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
  esac
}

fetch_index() {
  [[ -f "$INDEX" ]] && return 0
  # **stderr, like every other progress message here.**
  #
  # `ensure_binaries` returns the base directory by echoing it, and the caller
  # captures that with `base="$(ensure_binaries …)"`. Anything else this function
  # prints to stdout is captured too — so on a machine that has never run this
  # script, `base` became "Fetching binary index…" followed by the real path, and
  # the next line failed with
  #
  #     .../bin/mariadb-install-db: No such file or directory
  #
  # naming a file that is present and executable. Invisible to anyone who has run
  # the script before, because the index is then cached and this branch never
  # fires: it breaks the *first* run only, which is every new contributor and
  # every CI run.
  echo "Fetching binary index…" >&2
  curl -sSL --max-time 120 "$INDEX_URL" -o "$INDEX" || {
    echo "could not download $INDEX_URL" >&2; exit 1
  }
}

# Pulls url/sha256 for a version+platform out of the YAML index. The layout is
# fixed and shallow, so a windowed grep is enough and avoids a YAML dependency.
index_field() {
  local version="$1" plat="$2" field="$3"
  awk -v ver="            $version:" -v plat="                $plat:" -v field="                    $field:" '
    $0 == ver { inver = 1; next }
    inver && /^            [0-9]/ { inver = 0 }
    inver && $0 == plat { inplat = 1; next }
    inplat && /^                [a-z0-9_-]+:/ { inplat = 0 }
    inplat && index($0, field) == 1 { sub(/^[^:]*: */, ""); print; exit }
  ' "$INDEX"
}

# MySQL tarballs come straight from dev.mysql.com. Unlike the MariaDB index
# there is no published checksum manifest to verify against, which is a real
# downgrade in supply-chain terms — but the alternative is having no MySQL in
# the matrix at all, and that leaves caching_sha2 full auth, sha256_password,
# zstd, MySQL GTID and COM_BINLOG_DUMP_GTID permanently unverifiable.
# MySQL publishes macOS as `.tar.gz` and Linux as `.tar.xz`, and the script
# assumed gzip for both — so every Linux download 404'd, on x86_64 as well as
# aarch64. Invisible until something tried to run the fixtures off macOS, which
# nothing had.
mysql_archive_suffix() {
  [[ "$(uname -s)" == "Linux" ]] && echo "tar.xz" || echo "tar.gz"
}

mysql_url() {
  local version="$1" arch os
  case "$(uname -s)" in
    Darwin)
      [[ "$(uname -m)" == "arm64" ]] && arch="arm64" || arch="x86_64"
      os="macos14" ;;
    Linux)
      [[ "$(uname -m)" == "aarch64" ]] && arch="aarch64" || arch="x86_64"
      os="linux-glibc2.28" ;;
    *) echo "unsupported platform" >&2; return 1 ;;
  esac
  echo "https://dev.mysql.com/get/Downloads/MySQL-${version%.*}/mysql-${version}-${os}-${arch}.$(mysql_archive_suffix)"
}

ensure_mysql_binaries() {
  local version="$1"
  local base="$DIST/mysql-$version"
  [[ -x "$base/bin/mysqld" ]] && { echo "$base"; return 0; }

  local url archive tmp
  url="$(mysql_url "$version")"
  archive="$DIST/mysql-$version.$(mysql_archive_suffix)"
  echo "  downloading mysql ${version}…" >&2
  curl -sSL --max-time 900 "$url" -o "$archive" || { echo "download failed" >&2; exit 1; }

  tmp="$DIST/.unpack-mysql-$version"
  rm -rf "$tmp"; mkdir -p "$tmp"
  # `-a` picks the decompressor from the file, so the same line handles both.
  tar xaf "$archive" -C "$tmp" || { echo "unpack failed" >&2; exit 1; }
  mv "$tmp"/*/ "$base"
  rm -rf "$tmp" "$archive"
  echo "$base"
}

# Postgres binaries come from zonky's embedded-postgres jars on Maven Central.
#
# Not the doze-dev index, which is MariaDB only, and not Homebrew, which would
# make the fixture depend on what the developer happens to have installed. Maven
# Central is a stable unauthenticated URL with builds for every platform we care
# about, and the jar is just a zip holding a .txz.
# Postgres refuses to run as root outright — `initdb: cannot be run as root`,
# with no `--user` escape of the kind MySQL and MariaDB accept. A CI container is
# root, so everything Postgres runs through this.
#
# `setpriv` over `su` because it needs no login shell, no PAM, and no quoting of
# the command: the arguments pass through as given, which matters when they
# contain paths with spaces.
PG_USER="${SWIZZLE_PG_USER:-swizzlepg}"

ensure_pg_user() {
  [[ "$(id -u)" -eq 0 ]] || return 0
  id -u "$PG_USER" >/dev/null 2>&1 && return 0
  useradd --system --no-create-home --shell /usr/sbin/nologin "$PG_USER" 2>/dev/null \
    || adduser --system --no-create-home --shell /usr/sbin/nologin "$PG_USER" 2>/dev/null \
    || { echo "  could not create the unprivileged user Postgres needs" >&2; return 1; }
}

# Runs a Postgres command as that user when we are root, and unchanged otherwise.
pg_as_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    setpriv --reuid="$PG_USER" --regid="$PG_USER" --clear-groups "$@"
  else
    "$@"
  fi
}

postgres_platform() {
  local arch; arch="$(uname -m)"
  case "$(uname -s)" in
    Darwin) [[ "$arch" == "arm64" ]] && echo "darwin-arm64v8" || echo "darwin-amd64" ;;
    Linux)  [[ "$arch" == "aarch64" ]] && echo "linux-arm64v8" || echo "linux-amd64" ;;
    *) echo "unsupported platform: $(uname -s)" >&2; return 1 ;;
  esac
}

ensure_postgres_binaries() {
  local version="$1"
  local base="$DIST/postgres-$version"
  [[ -x "$base/bin/postgres" ]] && { echo "$base"; return 0; }

  local platform; platform="$(postgres_platform)" || return 1
  local url="https://repo1.maven.org/maven2/io/zonky/test/postgres"
  url="$url/embedded-postgres-binaries-$platform/$version"
  url="$url/embedded-postgres-binaries-$platform-$version.jar"

  echo "  downloading postgres $version ($platform)" >&2
  local jar="$DIST/postgres-$version.jar"
  curl -sSL --max-time 600 -o "$jar" "$url" || {
    echo "could not download $url" >&2; return 1
  }

  mkdir -p "$base"
  local staging="$DIST/.pg-$version"
  rm -rf "$staging"; mkdir -p "$staging"
  unzip -q -o "$jar" -d "$staging" || { echo "could not unpack $jar" >&2; return 1; }

  # One .txz inside, whose name encodes the platform differently from the jar's
  # (arm64v8 vs arm_64), so it is found rather than constructed.
  local archive; archive="$(find "$staging" -name 'postgres-*.txz' | head -1)"
  [[ -n "$archive" ]] || { echo "no postgres archive inside $jar" >&2; return 1; }
  tar -xJf "$archive" -C "$base" || { echo "could not extract $archive" >&2; return 1; }
  rm -rf "$staging" "$jar"

  [[ -x "$base/bin/postgres" ]] || { echo "postgres missing from $base" >&2; return 1; }
  echo "$base"
}

ensure_binaries() {
  local version="$1"
  local base="$DIST/mariadb-$version"
  [[ -x "$base/bin/mariadbd" ]] && { echo "$base"; return 0; }

  fetch_index
  local plat url sha
  plat="$(platform)"
  url="$(index_field "$version" "$plat" url)"
  sha="$(index_field "$version" "$plat" sha256)"
  if [[ -z "$url" ]]; then
    echo "no binary for mariadb $version on $plat" >&2; exit 1
  fi

  local archive="$DIST/mariadb-$version.tar.gz"
  echo "  downloading mariadb $version ($plat)…" >&2
  curl -sSL --max-time 600 "$url" -o "$archive" || { echo "download failed" >&2; exit 1; }

  if [[ -n "$sha" ]]; then
    local actual
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$sha" ]]; then
      echo "  checksum mismatch for $version" >&2
      echo "    expected $sha" >&2
      echo "    actual   $actual" >&2
      rm -f "$archive"
      exit 1
    fi
  fi

  local tmp="$DIST/.unpack-$version"
  rm -rf "$tmp"; mkdir -p "$tmp"
  tar xzf "$archive" -C "$tmp"
  # Archives contain a single top-level directory; normalise its name.
  mv "$tmp"/*/ "$base"
  rm -rf "$tmp" "$archive"
  echo "$base"
}

is_running() {
  local pidfile="$RUN/$1.pid"
  [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null && return 0

  # Postgres is started by pg_ctl, which writes `postmaster.pid` into the data
  # directory rather than anywhere this script chose. Checking only our own
  # pidfile reported a running server as stopped.
  local pgpid="$DATA/$1/postmaster.pid"
  [[ -f "$pgpid" ]] && kill -0 "$(head -1 "$pgpid")" 2>/dev/null
}

# The one certificate every fixture serves.
#
# Written here rather than left to each server because the alternative was three
# different certificates generated three different ways — see `testservers/
# tls.cnf` for what each of them was. The client stack is identical on both
# platforms, so the certificate was the only thing that could vary, and it was
# the only thing nobody had pinned.
#
# Bump `CERT_PARAMS_VERSION` to force every fixture to regenerate; the stamp is
# what makes an existing data directory pick up a change instead of keeping the
# certificate it was created with.
CERT_PARAMS_VERSION="1-rsa2048-sha256-san"

ensure_certificate() {
  local dir="$1"
  mkdir -p "$dir"

  if [[ -f "$dir/server.crt" && -f "$dir/server.key" \
     && "$(cat "$dir/server.params" 2>/dev/null)" == "$CERT_PARAMS_VERSION" ]]; then
    return 0
  fi

  rm -f "$dir/server.crt" "$dir/server.key" "$dir/server.params"
  openssl req -new -x509 -days 3650 -nodes \
    -newkey rsa:2048 -sha256 \
    -config "testservers/tls.cnf" \
    -out "$dir/server.crt" -keyout "$dir/server.key" >/dev/null 2>&1 || {
      echo "  could not generate a TLS certificate in $dir" >&2; return 1
    }
  # Postgres refuses to start if the key is group- or world-readable, and
  # MariaDB and MySQL are happy with the same.
  chmod 600 "$dir/server.key"
  echo "$CERT_PARAMS_VERSION" > "$dir/server.params"
}

start_server() {
  local name="$1" version="$2" port="$3" seed="$4" flavor="${5:-mariadb}"

  if is_running "$name"; then
    echo "  $name already running (:$port)"
    return 0
  fi

  if [[ "$flavor" == "mysql" ]]; then
    start_mysql_server "$name" "$version" "$port" "$seed"
    return $?
  fi

  if [[ "$flavor" == "postgres" ]]; then
    start_postgres_server "$name" "$version" "$port" "$seed"
    return $?
  fi

  local base datadir socket
  base="$(ensure_binaries "$version")"
  datadir="$DATA/$name"
  socket="$(socket_for "$port")"

  if [[ ! -d "$datadir/mysql" ]]; then
    rm -rf "$datadir"; mkdir -p "$datadir"
    # Initialisation errors used to go to /dev/null too, for the same reason the
    # seed's did: nobody had needed them yet.
    "$base/bin/mariadb-install-db" --basedir="$base" --datadir="$datadir" \
      --auth-root-authentication-method=normal > "$RUN/$name.init.log" 2>&1 || {
        echo "  $name: initialisation failed (see $RUN/$name.init.log)" >&2
        tail -5 "$RUN/$name.init.log" >&2
        return 1
      }
  fi

  # Small buffer pool: several servers on one machine, and the fixtures hold
  # trivial amounts of data.
  #
  # performance_schema is OFF by default in MariaDB (the MySQL Docker images
  # turn it on, which is why this was invisible before). Tests read
  # session_connect_attrs from it to verify connection attributes reach the
  # server, so it has to be enabled explicitly.
  # max_connections is raised well above the 151 default: the suite runs its
  # cases in parallel across five servers and legitimately opens hundreds of
  # short-lived connections, which saturated the default and surfaced as
  # unrelated tests failing with "Too many connections".
  #
  # Binary logging, for the replication/CDC tests. ROW format is what makes
  # row events carry actual before/after images — STATEMENT or MIXED would emit
  # QUERY events instead and the row-event decoder would never be exercised.
  # server_id must be unique per server or a replica connection is refused.
  # One server runs with binlog compression on so the compressed row-event path
  # is always exercised, while the other two keep covering the uncompressed one.
  # This is not a niche setting: with it enabled, a client that cannot decode
  # MARIADB_*_COMPRESSED events receives zero row changes and no error at all.
  # Expanded below as ${arr[@]+"${arr[@]}"}, not "${arr[@]}": macOS ships bash
  # 3.2, where an empty array under `set -u` is an "unbound variable" error —
  # which silently stopped the two servers that get no extra flags.
  local compress_flags=()
  if [[ "$name" == "mariadb114" ]]; then
    compress_flags=(--log-bin-compress=ON --log-bin-compress-min-len=10)
  fi

  # MariaDB 11.4 generates an **ephemeral** self-signed certificate when none is
  # configured — not written to disk, and new on every restart. So `have_ssl`
  # read YES on both platforms while the two were serving different
  # certificates, from different TLS libraries, and a different one after every
  # `test-servers.sh down && up`. Naming ours makes the TLS path reproducible.
  ensure_certificate "$datadir" || return 1

  "$base/bin/mariadbd" \
    ${root_user_flag[@]+"${root_user_flag[@]}"} \
    --basedir="$base" --datadir="$datadir" \
    --ssl-cert="$datadir/server.crt" --ssl-key="$datadir/server.key" \
    ${compress_flags[@]+"${compress_flags[@]}"} \
    --port="$port" --socket="$socket" --bind-address=127.0.0.1 \
    --innodb-buffer-pool-size=64M \
    --performance-schema=ON \
    --max-connections=512 \
    --log-bin="$datadir/binlog" \
    --binlog-format=ROW \
    --binlog-row-metadata=FULL \
    --server-id="$port" \
    --pid-file="$RUN/$name.pid" \
    > "$RUN/$name.log" 2>&1 &

  local deadline=$((SECONDS + 60))
  while [[ $SECONDS -lt $deadline ]]; do
    if "$base/bin/mariadb" -h 127.0.0.1 -P "$port" -u root -e "SELECT 1" >/dev/null 2>&1; then
      # Tracked by its own marker rather than by "did we just initialise", and
      # the MySQL path below has carried this fix for a while: the two come apart
      # the first time a server initialises successfully and then fails to start.
      # On the retry the data directory already exists, `fresh` is 0, the seed
      # silently never runs, and the server comes up with no users at all.
      #
      # MariaDB kept the older form purely because nobody looked at both paths at
      # once — the same sibling-asymmetry that left MySQL's connect unbounded
      # after Postgres's was fixed.
      if [[ ! -f "$datadir/.seeded" ]]; then
        # Errors to a file, not /dev/null. `mariadb118: seeding failed` with no
        # further detail is what a CI run reported, and there was no way to learn
        # more without another full cycle. MySQL's path has always logged this.
        "$base/bin/mariadb" -h 127.0.0.1 -P "$port" -u root \
          < "testservers/seed/$seed.sql" > "$RUN/$name.seed.log" 2>&1 || {
            echo "  $name: seeding failed (see $RUN/$name.seed.log)" >&2
            tail -5 "$RUN/$name.seed.log" >&2
            return 1
          }
        touch "$datadir/.seeded"

        # Optional plugins, applied separately and allowed to fail.
        #
        # Whether PARSEC can be installed is a property of the build, not the
        # version: the x86_64 Linux tarballs ship the client plugin without the
        # server one. Inside the main seed a single failing `INSTALL SONAME`
        # aborted every statement after it, so two servers came up with no users
        # at all and every suite against them failed for an unrelated reason.
        #
        # What was installed is recorded next to the data directory so the tests
        # can gate on the fixture's real capability rather than on a version
        # number the build does not honour.
        : > "$datadir/.plugins"
        if [[ -f "testservers/seed/optional-parsec.sql" && "$seed" == "parsec" ]]; then
          if "$base/bin/mariadb" -h 127.0.0.1 -P "$port" -u root \
               < "testservers/seed/optional-parsec.sql" > "$RUN/$name.parsec.log" 2>&1; then
            echo "parsec" >> "$datadir/.plugins"
          else
            echo "  $name: parsec unavailable in this build, skipping those suites" >&2
          fi
        fi
      fi
      echo "  $name  mariadb $version  :$port"
      return 0
    fi
    sleep 0.5
  done

  echo "  $name failed to start; last log lines:" >&2
  tail -5 "$RUN/$name.log" >&2
  return 1
}

# MySQL differs from MariaDB in three ways that matter here:
#   - initialisation is `mysqld --initialize-insecure`, not `mariadb-install-db`
#   - `caching_sha2_password` is the default plugin, and `sha256_password` must
#     be loaded explicitly with --early-plugin-load on 8.4+
#   - binary logging is on by default, but `server_id` still has to be set
start_mysql_server() {
  local name="$1" version="$2" port="$3" seed="$4"

  local base datadir socket
  base="$(ensure_mysql_binaries "$version")"
  datadir="$DATA/$name"
  socket="$(socket_for "$port")"

  # Seeding is tracked by its own marker rather than by "did we just
  # initialise". Those came apart the first time a server initialised
  # successfully and then failed to start: on the retry the datadir already
  # existed, so the seed silently never ran and the server came up with no
  # users at all.
  if [[ ! -d "$datadir/mysql" ]]; then
    rm -rf "$datadir"; mkdir -p "$datadir"
    "$base/bin/mysqld" --initialize-insecure ${root_user_flag[@]+"${root_user_flag[@]}"} \
      --basedir="$base" --datadir="$datadir" \
      --log-error="$RUN/$name.init.log" >/dev/null 2>&1 || {
        echo "  $name: initialisation failed (see $RUN/$name.init.log)" >&2; return 1
      }
  fi

  # mysql_native_password is disabled by default in 8.4 and **removed outright
  # in 9.0**, so the flag is version-gated: passing it to 9.x aborts startup
  # with "unknown variable".
  local native_password_flag=()
  case "$version" in
    8.*) native_password_flag=(--mysql-native-password=ON) ;;
  esac
  # MySQL writes its auto-generated certificates to the data directory rather
  # than keeping them in memory the way MariaDB does, so these were at least
  # stable across restarts — but still one certificate per platform, from that
  # platform's build. Same certificate as the others now.
  ensure_certificate "$datadir" || return 1

  "$base/bin/mysqld" \
    ${root_user_flag[@]+"${root_user_flag[@]}"} \
    --basedir="$base" --datadir="$datadir" \
    --ssl-cert="$datadir/server.crt" --ssl-key="$datadir/server.key" \
    --port="$port" --socket="$socket" --bind-address=127.0.0.1 \
    --mysqlx=OFF \
    --innodb-buffer-pool-size=64M \
    --performance-schema=ON \
    --max-connections=512 \
    --local-infile=ON \
    --server-id="$port" \
    --log-bin="$datadir/binlog" \
    --binlog-format=ROW \
    --binlog-row-metadata=FULL \
    --gtid-mode=ON --enforce-gtid-consistency=ON \
    --binlog-transaction-compression=OFF \
    --binlog-row-value-options="" \
    --protocol-compression-algorithms=zlib,zstd,uncompressed \
    ${native_password_flag[@]+"${native_password_flag[@]}"} \
    --pid-file="$RUN/$name.pid" \
    > "$RUN/$name.log" 2>&1 &

  local deadline=$((SECONDS + 90))
  while [[ $SECONDS -lt $deadline ]]; do
    if "$base/bin/mysql" -h 127.0.0.1 -P "$port" -u root --skip-password \
         -e "SELECT 1" >/dev/null 2>&1; then
      if [[ ! -f "$datadir/.seeded" ]]; then
        "$base/bin/mysql" -h 127.0.0.1 -P "$port" -u root --skip-password \
          < "testservers/seed/$seed.sql" > "$RUN/$name.seed.log" 2>&1 || {
            echo "  $name: seeding failed (see $RUN/$name.seed.log)" >&2; return 1
          }
        touch "$datadir/.seeded"

        # Optional plugins, applied separately and allowed to fail.
        #
        # Whether PARSEC can be installed is a property of the build, not the
        # version: the x86_64 Linux tarballs ship the client plugin without the
        # server one. Inside the main seed a single failing `INSTALL SONAME`
        # aborted every statement after it, so two servers came up with no users
        # at all and every suite against them failed for an unrelated reason.
        #
        # What was installed is recorded next to the data directory so the tests
        # can gate on the fixture's real capability rather than on a version
        # number the build does not honour.
        : > "$datadir/.plugins"
        if [[ -f "testservers/seed/optional-parsec.sql" && "$seed" == "parsec" ]]; then
          if "$base/bin/mariadb" -h 127.0.0.1 -P "$port" -u root \
               < "testservers/seed/optional-parsec.sql" > "$RUN/$name.parsec.log" 2>&1; then
            echo "parsec" >> "$datadir/.plugins"
          else
            echo "  $name: parsec unavailable in this build, skipping those suites" >&2
          fi
        fi
      fi
      echo "  $name  mysql $version  :$port"
      return 0
    fi
    sleep 0.4
  done
  echo "  $name: did not start (see $RUN/$name.log)" >&2
  tail -3 "$RUN/$name.log" >&2 || true
  return 1
}

start_postgres_server() {
  local name="$1" version="$2" port="$3" seed="$4"
  local base data
  base="$(ensure_postgres_binaries "$version")" || return 1
  data="$DATA/$name"

  if is_running "$port"; then
    echo "  $name already listening on $port"
    return 0
  fi

  if [[ ! -f "$data/PG_VERSION" ]]; then
    echo "  initialising $name"
    rm -rf "$data"; mkdir -p "$data"
    # Trust auth on loopback: this is a disposable fixture, and a password file
    # would be one more thing to keep in step with the test credentials.
    ensure_pg_user || return 1
    # The data directory has to belong to the user that will own the postmaster,
    # and so does the log initdb writes.
    if [[ "$(id -u)" -eq 0 ]]; then
      mkdir -p "$data" "$RUN"
      chown -R "$PG_USER" "$data" "$RUN" 2>/dev/null || true
    fi
    pg_as_user "$base/bin/initdb" -D "$data" -U postgres --auth=trust --encoding=UTF8 \
      >"$RUN/$name.init.log" 2>&1 || {
        echo "  initdb failed — see $RUN/$name.init.log" >&2; return 1
      }

    # Seeded in single-user mode, before the postmaster starts.
    #
    # The embedded builds ship `initdb`, `pg_ctl` and `postgres` and nothing
    # else — no `psql` — so there is no client to seed with. `postgres --single`
    # is the server acting as its own client, which is exactly what this needs
    # and removes a dependency on whatever Postgres the developer has installed.
    #
    # One statement per line: single-user mode terminates on newline, not on a
    # semicolon, so a statement split across lines is read as several.
    printf '%s\n' \
      "CREATE DATABASE swizzle_test" \
      | pg_as_user "$base/bin/postgres" --single -D "$data" postgres \
        >>"$RUN/$name.init.log" 2>&1 || {
          echo "  creating swizzle_test failed — see $RUN/$name.init.log" >&2; return 1
        }
    printf '%s\n' \
      "CREATE ROLE swizzle LOGIN SUPERUSER PASSWORD 'swizzlepass'" \
      | pg_as_user "$base/bin/postgres" --single -D "$data" swizzle_test \
        >>"$RUN/$name.init.log" 2>&1 || {
          echo "  creating the swizzle role failed — see $RUN/$name.init.log" >&2; return 1
        }
  fi

  # Authentication fixtures, applied on every start so an existing data
  # directory picks them up too.
  #
  # initdb's `--auth=trust` means the server never asks for a password, so
  # SCRAM-SHA-256 — the default for every modern Postgres, and this driver's
  # main auth path — would otherwise never run against a real server at all.
  # RFC test vectors prove the maths; they do not prove the exchange.
  #
  # pg_hba is **first match wins**, so the per-user rules must precede the
  # catch-all trust line or they are dead entries.
  # A self-signed certificate, so TLS — and with it SCRAM channel binding — can
  # be exercised at all. Without one the driver's whole TLS path and the
  # `-PLUS` mechanism are unreachable, which is how SCRAM itself shipped broken
  # under `--auth=trust`.
  # This used to be an inline `openssl req` with only `-subj`, which meant the
  # key size, digest and extensions all came from the host's openssl.cnf —
  # LibreSSL 3.3.6 on macOS, OpenSSL 3.0.2 in the container. Same call, two
  # certificates.
  ensure_certificate "$data" || { echo "  $name: no TLS certificate" >&2; return 1; }
  # The key must belong to the user the postmaster runs as, which is not this
  # one when we are root. `chmod 600` plus root ownership is exactly the
  # combination that yields `could not load private key file: Permission
  # denied` — the key is locked down correctly and to the wrong account.
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$PG_USER" "$data/server.crt" "$data/server.key" 2>/dev/null || true
  fi

  # `hostssl` for the channel-binding user: the rule only matches an encrypted
  # connection, so a client that skipped TLS cannot reach it at all.
  cat > "$data/pg_hba.conf" <<'HBA'
local   all             all                                     trust
hostssl all             swizzle_cb      127.0.0.1/32            scram-sha-256
host    all             swizzle_scram   127.0.0.1/32            scram-sha-256
host    all             swizzle_md5     127.0.0.1/32            md5
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
HBA

  # Roles for those rules. `CREATE ROLE` fails when the role already exists, and
  # that is the expected case on every start after the first — so failure is
  # ignored rather than checked.
  #
  # `password_encryption` decides which verifier is *stored*, and a role whose
  # stored verifier is SCRAM cannot authenticate with md5 however the hba line
  # reads. So each role is created under the setting that matches its rule.
  printf '%s\n' \
    "CREATE ROLE swizzle_scram LOGIN SUPERUSER PASSWORD 'scrampass'" \
    | pg_as_user "$base/bin/postgres" --single -D "$data" -c password_encryption=scram-sha-256 \
      swizzle_test >>"$RUN/$name.init.log" 2>&1 || true
  printf '%s\n' \
    "CREATE ROLE swizzle_md5 LOGIN SUPERUSER PASSWORD 'md5pass'" \
    | pg_as_user "$base/bin/postgres" --single -D "$data" -c password_encryption=md5 \
      swizzle_test >>"$RUN/$name.init.log" 2>&1 || true
  # Reachable only over TLS, via the `hostssl` rule above — which is what makes
  # SCRAM-SHA-256-PLUS testable at all.
  printf '%s\n' \
    "CREATE ROLE swizzle_cb LOGIN SUPERUSER PASSWORD 'cbpass'" \
    | pg_as_user "$base/bin/postgres" --single -D "$data" -c password_encryption=scram-sha-256 \
      swizzle_test >>"$RUN/$name.init.log" 2>&1 || true

  echo "  starting $name on $port"
  # `-k` puts the unix socket in /tmp for the same reason MySQL's does: macOS
  # caps socket paths at 103 bytes and the project directory blows past it.
  pg_as_user "$base/bin/pg_ctl" -D "$data" -l "$RUN/$name.log" -w -t 30 \
    -o "-p $port -k /tmp -c listen_addresses=127.0.0.1 -c wal_level=logical -c ssl=on -c ssl_cert_file=$data/server.crt -c ssl_key_file=$data/server.key" \
    start >/dev/null 2>&1 || {
      echo "  $name failed to start — see $RUN/$name.log" >&2; return 1
    }
  return 0
}

stop_postgres_server() {
  local name="$1" version="$2"
  local base="$DIST/postgres-$version"
  local data="$DATA/$name"
  [[ -x "$base/bin/pg_ctl" && -d "$data" ]] || return 0
  pg_as_user "$base/bin/pg_ctl" -D "$data" -m fast stop >/dev/null 2>&1 || true
}

stop_server() {
  local name="$1" version="${2:-}" port="${3:-}" seed="${4:-}" flavor="${5:-mariadb}"

  # Postgres is stopped by pg_ctl rather than by signalling a pidfile we wrote,
  # because pg_ctl owns the postmaster's shutdown handshake.
  if [[ "$flavor" == "postgres" ]]; then
    stop_postgres_server "$name" "$version"
    # Reported like the others. While Postgres was silently not being stopped,
    # `down` printed five lines for six servers and nobody counted.
    echo "  $name stopped"
    return 0
  fi

  local pidfile="$RUN/$name.pid"
  [[ -f "$pidfile" ]] || return 0
  local pid; pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    local deadline=$((SECONDS + 30))
    while kill -0 "$pid" 2>/dev/null && [[ $SECONDS -lt $deadline ]]; do sleep 0.3; done
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$pidfile"
  echo "  $name stopped"
}

# Runs `action` over every configured server, passing **all five** fields.
#
# Process substitution rather than a pipe, and the difference is not stylistic:
# a piped `while` runs in a subshell, so `return 1` inside it sets only that
# subshell's status and the loop carries on. `each_server start_server || exit 1`
# therefore reported whatever the *last* server did and a failure in the middle
# was invisible.
each_server() {
  local action="$1" failed=0
  while read -r name version port seed flavor; do
    "$action" "$name" "$version" "$port" "$seed" "${flavor:-mariadb}" || failed=1
  done < <(grep -vE '^\s*(#|$)' "$CONF")
  return $failed
}

case "${1:-up}" in
  up)
    echo "Starting MariaDB and MySQL test servers (native, no Docker)…"
    each_server start_server || exit 1
    ;;
  # All three of these went through `while read -r name _ _ _`, which discarded
  # the flavour — so `stop_server` defaulted to `mariadb` for every server,
  # looked for a pidfile Postgres does not write, and returned success without
  # stopping it. `down` quietly left the postmaster running, and `reset` and
  # `clean` then `rm -rf`'d the data directory **out from under it**. The
  # command you reach for when the fixtures are broken was able to break them
  # further. `each_server` passes all five fields.
  down)
    each_server stop_server
    ;;
  reset)
    each_server stop_server
    rm -rf "$DATA"
    mkdir -p "$DATA"
    echo "Data directories wiped; rebuilding…"
    each_server start_server || exit 1
    ;;
  clean)
    each_server stop_server
    rm -rf "$ROOT"
    echo "Removed $ROOT (binaries and data)."
    ;;
  status)
    # The flavour was hardcoded to `mariadb`, so `status` cheerfully reported
    # "postgres16 mariadb 16.4.0" and "mysql84 mariadb 8.4.3".
    while read -r name version port _ flavor; do
      if is_running "$name"; then
        printf "  %-12s %-8s %-8s :%s  running\n" "$name" "${flavor:-mariadb}" "$version" "$port"
      else
        printf "  %-12s %-8s %-8s :%s  stopped\n" "$name" "${flavor:-mariadb}" "$version" "$port"
      fi
    done < <(grep -vE '^\s*(#|$)' "$CONF")
    ;;
  *)
    echo "usage: $0 {up|down|reset|status|clean}" >&2
    exit 2
    ;;
esac
