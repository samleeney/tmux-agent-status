#!/usr/bin/env bash

# Run a collector under a nonblocking kernel lock. Never unlink the lock file:
# replacing its inode would let a second process lock a different file.
lock_file="$1"
shift

if command -v flock >/dev/null 2>&1; then
    exec flock -n -E 0 "$lock_file" "$@"
elif command -v perl >/dev/null 2>&1; then
    # Use Perl on systems without the flock utility, including macOS. Preserve
    # the locked descriptor across exec; the kernel releases it on exit.
    exec perl -MFcntl=:flock,F_SETFD -MErrno=EAGAIN,EWOULDBLOCK -e '
        my $path = shift @ARGV;
        open my $lock, ">>", $path or die "Cannot open collector lock: $!\n";
        unless (flock($lock, LOCK_EX | LOCK_NB)) {
            exit 0 if $! == EAGAIN || $! == EWOULDBLOCK;
            die "Cannot acquire collector lock: $!\n";
        }
        fcntl($lock, F_SETFD, 0) or die "Cannot retain collector lock: $!\n";
        exec @ARGV;
        die "Cannot start collector: $!\n";
    ' -- "$lock_file" "$@"
fi

echo 'tmux-agent-status: the collector requires flock or Perl for locking' >&2
exit 1
