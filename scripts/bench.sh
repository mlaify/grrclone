#!/usr/bin/env bash
#
# grrclone M0 benchmark gate.
#
# Measures the exact stack grrclone plans to ship — `rclone serve nfs` on a fixed
# loopback port, mounted with our own hardened option string — against `rclone copy`
# as the baseline. If NFS cannot sustain a usable fraction of the baseline, the
# WebDAV/NetFS transport becomes the default instead.
#
# Everything it creates is namespaced under grrclone-bench-<pid> and removed on exit,
# including on Ctrl-C.
#
# Usage:  scripts/bench.sh <remote:>  [size]
#   e.g.  scripts/bench.sh dav1: 256M
#
set -uo pipefail

REMOTE="${1:?usage: bench.sh <remote:> [size]}"
SIZE="${2:-256M}"
NFILES="${NFILES:-1000}"

RCLONE="$(command -v rclone)"
STAMP="$(date +%Y%m%d-%H%M%S)"
TAG="grrclone-bench-$$"
WORK="$(mktemp -d "/tmp/${TAG}.XXXXXX")"
MNT="$HOME/grrclone-bench-mnt"
RESULTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/bench-results"
RESULTS="$RESULTS_DIR/${STAMP}.tsv"
LOG="$WORK/rclone.log"
CACHE="$WORK/cache"
REMOTE_DIR="${REMOTE}${TAG}"

SERVE_PID=""
MOUNTED=0

mkdir -p "$RESULTS_DIR" "$CACHE" "$MNT"

# ---------------------------------------------------------------- reporting ---
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }

# Wall-clock seconds for a command, printed to stdout. Output of the command is
# discarded; failures are reported as the sentinel FAIL.
timeit() {
  local start end
  start=$(python3 -c 'import time;print(time.time())')
  if ! "$@" >/dev/null 2>&1; then echo "FAIL"; return 1; fi
  end=$(python3 -c 'import time;print(time.time())')
  python3 -c "print(f'{$end-$start:.2f}')"
}

mbps() { # bytes seconds -> MB/s
  python3 -c "
s=float('$2') if '$2'!='FAIL' else 0
print('n/a' if s<=0 else f'{$1/s/1048576:.1f}')"
}

# ------------------------------------------------------------------ cleanup ---
cleanup() {
  local rc=$?
  say "Cleanup"
  if [[ $MOUNTED -eq 1 ]]; then
    note "unmounting $MNT"
    diskutil umount force "$MNT" >/dev/null 2>&1 || umount -f "$MNT" >/dev/null 2>&1
  fi
  if [[ -n "$SERVE_PID" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
    note "stopping rclone serve (pid $SERVE_PID)"
    kill "$SERVE_PID" 2>/dev/null
    wait "$SERVE_PID" 2>/dev/null
  fi
  note "removing remote test dir $REMOTE_DIR"
  "$RCLONE" purge "$REMOTE_DIR" >/dev/null 2>&1
  rmdir "$MNT" 2>/dev/null
  note "local scratch left at $WORK (remove manually if you don't need the log)"
  exit $rc
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------- free port ---
free_port() {
  python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}

wait_for_port() { # port timeout_s
  local port="$1" deadline
  deadline=$(python3 -c "import time;print(time.time()+$2)")
  while python3 -c "import time,sys; sys.exit(0 if time.time()<$deadline else 1)"; do
    if python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1',$port))==0 else 1)"; then return 0; fi
    sleep 0.1
  done
  return 1
}

# ------------------------------------------------------- serve + mount NFS ---
# $1 = nfs cache type (memory|disk)
start_nfs() {
  local cachetype="$1" port
  port="$(free_port)"

  "$RCLONE" serve nfs "$REMOTE_DIR" \
    --addr "localhost:$port" \
    --vfs-cache-mode full \
    --nfs-cache-type "$cachetype" \
    --nfs-cache-dir "$CACHE/nfs-$cachetype" \
    --cache-dir "$CACHE/vfs" \
    --dir-cache-time 30s \
    --poll-interval 1m \
    --log-file "$LOG" --log-level INFO &
  SERVE_PID=$!

  if ! wait_for_port "$port" 15; then
    note "server never came up; last log lines:"; tail -5 "$LOG"; return 1
  fi

  # The option set rclone's own nfsmount will NOT give us. soft+intr+timeo means a
  # dead backend returns an error instead of wedging Finder forever; nolocks because
  # rclone's NFS server runs no lock daemon.
  local opts="port=$port,mountport=$port,tcp,soft,intr,timeo=600,retrans=2"
  opts="$opts,nolocks,locallocks,nfc,rsize=131072,wsize=131072"

  if ! /sbin/mount -t nfs -o "$opts" localhost:/ "$MNT" 2>"$WORK/mount.err"; then
    note "mount failed: $(cat "$WORK/mount.err")"; return 1
  fi
  MOUNTED=1
  note "mounted $REMOTE_DIR at $MNT (nfs-cache-type=$cachetype, port=$port)"
}

stop_nfs() {
  if [[ $MOUNTED -eq 1 ]]; then
    diskutil umount force "$MNT" >/dev/null 2>&1 || umount -f "$MNT" >/dev/null 2>&1
    MOUNTED=0
  fi
  if [[ -n "$SERVE_PID" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null
  fi
  SERVE_PID=""
}

# With --vfs-cache-mode full, a read that hits the VFS cache never touches the
# network and a write returns before the upload starts. Both make the mount look
# thousands of MB/s fast and measure nothing. Purge the cache so "cold" means cold.
purge_vfs_cache() { rm -rf "$CACHE/vfs" "$CACHE/nfs-"* 2>/dev/null; mkdir -p "$CACHE/vfs"; }

# Size of a file as the BACKEND sees it, bypassing the mount entirely. Used to wait
# for a write to be genuinely durable rather than merely queued.
remote_size() {
  "$RCLONE" lsjson "$REMOTE_DIR/$1" 2>/dev/null \
    | python3 -c "
import json,sys
try: print(json.load(sys.stdin)[0]['Size'])
except Exception: print(-1)"
}

# Poll the backend until the uploaded file matches the expected size. Returns the
# extra seconds spent waiting after dd returned, or FAIL on timeout.
wait_for_upload() { # name expected_bytes timeout_s
  local name="$1" want="$2" deadline start
  start=$(python3 -c 'import time;print(time.time())')
  deadline=$(python3 -c "import time;print(time.time()+$3)")
  while python3 -c "import time,sys; sys.exit(0 if time.time()<$deadline else 1)"; do
    [[ "$(remote_size "$name")" == "$want" ]] && {
      python3 -c "import time;print(f'{time.time()-$start:.2f}')"; return 0; }
    sleep 1
  done
  echo FAIL; return 1
}

# ================================================================== run =======
printf 'metric\tvariant\tvalue\tunit\n' > "$RESULTS"

say "grrclone M0 benchmark"
note "rclone:   $("$RCLONE" version | head -1)"
note "remote:   $REMOTE   test dir: $REMOTE_DIR"
note "size:     $SIZE     small files: $NFILES"
note "results:  $RESULTS"

say "Preparing local test data"
mkfile -n "$SIZE" "$WORK/big.bin" 2>/dev/null || \
  dd if=/dev/urandom of="$WORK/big.bin" bs=1m count="${SIZE%M}" 2>/dev/null
BYTES=$(stat -f %z "$WORK/big.bin")
note "$WORK/big.bin = $BYTES bytes"

mkdir -p "$WORK/many"
for i in $(seq 1 "$NFILES"); do printf 'x' > "$WORK/many/file-$i.txt"; done
note "$NFILES small files staged"

# ---------------------------------------------------------------- baseline ---
say "Baseline: rclone copy (no mount involved)"
t=$(timeit "$RCLONE" copy "$WORK/big.bin" "$REMOTE_DIR/" --transfers 4)
note "upload   ${t}s  $(mbps "$BYTES" "$t") MB/s"
record upload_baseline rclone_copy "$(mbps "$BYTES" "$t")" MB/s

t=$(timeit "$RCLONE" copy "$REMOTE_DIR/big.bin" "$WORK/dl-baseline/" --transfers 4)
note "download ${t}s  $(mbps "$BYTES" "$t") MB/s"
record download_baseline rclone_copy "$(mbps "$BYTES" "$t")" MB/s

say "Staging $NFILES small files on the remote for the listing test"
"$RCLONE" copy "$WORK/many" "$REMOTE_DIR/many/" --transfers 16 >/dev/null 2>&1
t=$(timeit "$RCLONE" lsjson "$REMOTE_DIR/many")
note "baseline listing of $NFILES entries: ${t}s"
record list_baseline rclone_lsjson "$t" s

# ------------------------------------------------------------- NFS variants ---
for CT in disk memory; do
  say "NFS transport — --nfs-cache-type $CT"
  purge_vfs_cache
  if ! start_nfs "$CT"; then note "SKIPPED (setup failed)"; stop_nfs; continue; fi

  # COLD read is the headline number: the cache is empty, so this is what a user
  # actually waits for the first time they open a file in Finder. Compare it to the
  # download baseline, not to the warm run.
  t=$(timeit dd if="$MNT/big.bin" of=/dev/null bs=1m)
  note "read  COLD   ${t}s  $(mbps "$BYTES" "$t") MB/s   <-- vs baseline download"
  record read_cold "nfs_$CT" "$(mbps "$BYTES" "$t")" MB/s

  # WARM read serves from the local VFS cache and never touches the network. Recorded
  # only to confirm caching works; it is not a transport measurement.
  t=$(timeit dd if="$MNT/big.bin" of=/dev/null bs=1m)
  note "read  warm   ${t}s  $(mbps "$BYTES" "$t") MB/s   (local cache, not network)"
  record read_warm "nfs_$CT" "$(mbps "$BYTES" "$t")" MB/s

  # WRITE must include the upload, not just the copy into the cache. dd returns as
  # soon as the bytes are local; the honest number is dd plus the drain.
  wname="written-$CT.bin"
  t=$(timeit dd if="$WORK/big.bin" of="$MNT/$wname" bs=1m)
  note "write dd     ${t}s  (into VFS cache only)"
  drain=$(wait_for_upload "$wname" "$BYTES" 600)
  if [[ "$drain" == "FAIL" ]]; then
    note "write upload did not complete within 600s — FAIL"
    record write_end_to_end "nfs_$CT" FAIL MB/s
  else
    total=$(python3 -c "print(f'{$t+$drain:.2f}')")
    note "write drain  ${drain}s"
    note "write TOTAL  ${total}s  $(mbps "$BYTES" "$total") MB/s   <-- vs baseline upload"
    record write_end_to_end "nfs_$CT" "$(mbps "$BYTES" "$total")" MB/s
  fi

  # Directory listing. Cold here means the dir cache has not seen it yet.
  t=$(timeit ls -l "$MNT/many")
  note "ls cold      ${t}s  ($NFILES entries)"
  record list_cold "nfs_$CT" "$t" s
  t=$(timeit ls -l "$MNT/many")
  note "ls warm      ${t}s"
  record list_warm "nfs_$CT" "$t" s

  stop_nfs
done

# ------------------------------------------------------------- kill test -----
say "Crash test: SIGKILL the server with the mount live"
if start_nfs disk; then
  note "killing rclone (pid $SERVE_PID) with mount held open"
  kill -9 "$SERVE_PID" 2>/dev/null; SERVE_PID=""
  sleep 1

  # The whole point of soft,intr,timeo: this must return, not hang forever.
  note "probing the dead mount (must return within ~30s, not hang)..."
  probe_start=$(python3 -c 'import time;print(time.time())')
  ( ls "$MNT" >/dev/null 2>&1 ) & probe=$!
  waited=0
  while kill -0 $probe 2>/dev/null && [[ $waited -lt 60 ]]; do sleep 1; waited=$((waited+1)); done
  if kill -0 $probe 2>/dev/null; then
    kill -9 $probe 2>/dev/null
    note "RESULT: probe HUNG past 60s — hard-mount behaviour, BAD"
    record kill_recovery soft_mount hung s
  else
    probe_end=$(python3 -c 'import time;print(time.time())')
    el=$(python3 -c "print(f'{$probe_end-$probe_start:.1f}')")
    note "RESULT: probe returned after ${el}s — mount degraded gracefully, GOOD"
    record kill_recovery soft_mount "$el" s
  fi

  note "force-unmounting the dead mount"
  if diskutil umount force "$MNT" >/dev/null 2>&1; then
    note "RESULT: diskutil umount force succeeded — recoverable without reboot"
    record kill_unmount diskutil_force ok -
  else
    note "RESULT: diskutil umount force FAILED — this is the reboot scenario"
    record kill_unmount diskutil_force failed -
  fi
  MOUNTED=0
fi

# ------------------------------------------------------------------ report ---
say "Results"
column -t -s $'\t' "$RESULTS"
say "Saved to $RESULTS"
