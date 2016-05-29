#!/bin/sh

warn () {
	echo >&2 -e "$*"
}

fatal () {
	die "fatal: $*"
}

head_ref () {
	git symbolic-ref --short -q HEAD
}

on_branch () {
	test "$(head_ref)" = "$1"
}

valid_ref () {
	git rev-parse --quiet --verify "$@" >/dev/null
}

cherry_pick_active () {
	# Ideally git rebase would have some plumbing for this, so
	# we wouldn't have to assume knowledge of internals.
	valid_ref CHERRY_PICK_HEAD
}

rebase_active () {
	# Ideally git rebase would have some plumbing for this, so
	# we wouldn't have to assume knowledge of internals.  See:
	# http://stackoverflow.com/questions/3921409/how-to-know-if-there-is-a-git-rebase-in-progress
	test -e "$git_dir/rebase-merge" ||
	    test -e "$git_dir/rebase-apply"
}

in_progress_error () {
	cat <<EOF >&2
$*

git $workflow already in progress; please complete it, or run

  git $workflow --abort
EOF
	exit 1
}

ensure_cherry_pick_not_in_progress () {
	if cherry_pick_active
	then
		fatal "Can't start git $workflow when there is"\
		      "a cherry-pick in progress"
	fi
}

ensure_rebase_not_in_progress () {
	if rebase_active
	then
		warn "Can't start git $workflow when there is"\
		     "a rebase in progress."

		# We know this will fail; we run it because we want to output
		# the same error message which git-rebase uses to tell the user
		# to finish or abort their in-flight rebase.
		git rebase
		exit 1
	fi
}
