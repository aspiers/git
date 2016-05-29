#!/bin/bash
#
# git-transplant - Transplant commits from one branch to another
# Copyright (c) 2016 Adam Spiers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# ---------------------------------------------------------------------
#

dashless=$(basename "$0" | sed -e 's/-/ /')
USAGE="[--new-from=<branch> | --after=<commit-ish>] <range> <dest-branch>
   or: $dashless (--continue | --abort)"
LONG_USAGE=\
'  -h, --help          Show this help and exit
  -a, --after=REF     Transplant into inside DEST-BRANCH after the given ref
  -n, --new-from=REF  First create DEST-BRANCH starting at REF
      --continue      Continue an in-progress transplant
      --abort         Abort an in-progress transplant
      --in-progress   Exit 0 if and only if a transplant is in progress
'

OPTIONS_SPEC=
. git-sh-setup
. git-splice--lib

# Useful when debugging with bash; harmless otherwise
PS4="+\${BASH_SOURCE/\$HOME/\~}@\${LINENO}(\${FUNCNAME[0]}): " \
   && export PS4

me=$(basename $0)
git_dir=$(git rev-parse --git-dir) || exit 1
transplant_dir="$git_dir/transplant"
src_branch_file="$transplant_dir/src-branch"
dest_branch_file="$transplant_dir/dest-branch"
dest_branch_created_file="$transplant_dir/dest-branch-created"
dest_branch_orig_sha_file="$transplant_dir/dest-branch-orig-sha"
after_file="$transplant_dir/after"
insert_todo="$transplant_dir/insert-todo"
remove_todo="$transplant_dir/remove-todo"
splice_file="$transplant_dir/splice-in-progress"
workflow=transplant

. "$(git --exec-path)/git-sh-setup"

main () {
	parse_opts "$@"

	if test -n "$in_progress"
	then
		if in_progress
		then
			echo "Transplant in progress: $reason"
			exit 0
		else
			echo "Transplant not in progress"
			exit 1
		fi
	fi

	if test -n "$abort" || test -n "$continue"
	then
		ensure_transplant_in_progress
	else
		# Needs to happen before parse_args(), otherwise the in-flight
		# files will already exist.
		ensure_transplant_not_in_progress
		ensure_cherry_pick_not_in_progress
		ensure_rebase_not_in_progress
		require_clean_work_tree transplant "Please commit or stash them."
	fi

	parse_args "${ARGV[@]}"

	src_branch="$(cat $src_branch_file)"
	dest_branch="$(cat $dest_branch_file)"

	if test -n "$abort"
	then
		transplant_abort
		return
	fi

	# Handle both normal execution and --continue
	transplant
}

read_branches_from_files () {
	if ! test -f "$src_branch_file"
	then
		die "BUG: $src_branch_file was not a valid file"
	fi
	if ! test -f "$dest_branch_file"
	then
		die "BUG: $dest_branch_file was not a valid file"
	fi

	if test -z "$src_branch"
	then
		die "BUG: $src_branch_file was empty"
	fi
	if test -z "$dest_branch"
	then
		die "BUG: $dest_branch_file was empty"
	fi
}

transplant () {
	read_branches_from_files
	prep_dest_branch

	# If we're in a --continue then the insertion might have
	# already completed.
	if test -s "$insert_todo"
	then
		insert_range
	fi

	# I can't think why the remove file would be empty,
	# but you never know.
	if test -s "$remove_todo"
	then
		remove_range
	fi
}

prep_dest_branch () {
	if test -n "$continue"
	then
		return
	fi

	if test -n "$new_from"
	then
		if git checkout -b "$dest_branch" "$new_from"
		then
			touch "$dest_branch_created_file"
		else
			cleanup
			fatal "Couldn't create $dest_branch at $new_from"
		fi
	else
		if ! git checkout "$dest_branch"
		then
			cleanup
			fatal "Couldn't checkout $dest_branch"
		fi
	fi
}

announce_action () {
	set +x
	echo "###############################################################"
	echo "# $action"
	if test -n "$debug"
	then
		set -x
	fi
}

insert_range () {
	if test -s "$after_file"
	then
		action="insert into $dest_branch"
	else
		action="insert onto $dest_branch"
	fi

	announce_action

	if test -z "$continue"
	then
		if test -s "$after_file"
		then
			insertion_point="$(cat $after_file)"
		else
			# Of course we could just cherry-pick here, but this would
			# mean handling an extra path in the workflow.  By always
			# performing insertion via splice, we simplify handling of the
			# workflow, especially when things go wrong.
			insertion_point="$dest_branch"
		fi

		args=( "$insertion_point" -- "$(cat $insert_todo)" )
	else
		args=( --continue )

		if test -e "$splice_file"
		then
			check_splice_file_action
		else
			warn "$splice_file was missing; continuing splice anyway ..."
		fi
	fi

	echo "$action" >"$splice_file"
	if git_splice "${args[@]}"
	then
		rm "$insert_todo" "$splice_file"
		return 0
	else
		ret=$?
	fi

	if git_splice --in-progress >/dev/null
	then
		# splice must have failed due to conflicts. It will have
		# already output the correct error message, so just wait
		# for the user to do transplant --abort or --continue.
		exit $ret
	fi

	# Otherwise splice must have failed early on, before starting the
	# workflow.  It will have already output the correct error
	# message, so just clean up and bail.
	cleanup
	exit $ret
}

git_splice () {
	echo git splice $debug --transplant "$@"
	git splice $debug --transplant "$@"
}

check_splice_file_action () {
	if ! grep -q "$action" "$splice_file"
	then
		fatal "$splice_file contained:

$(cat $splice_file)

but was expecting:

$action"
	fi
}

remove_range () {
	if ! rebase_active
	then
		git checkout "$src_branch"
	fi

	action="remove from $src_branch"
	if test -z "$continue" && test -e "$splice_file"
	then
		die "BUG: $splice_file should not exist at this point"
	fi

	announce_action

	if remove_command
	then
		rm -rf "$transplant_dir"
		exit 0
	else
		# splice must have failed, but we don't care whether that was
		# due to conflicts or something else - either way, we're still
		# in the middle of the transplant workflow, it will have
		# already output the correct error message, so just wait for
		# the user to do transplant --abort or --continue.
		exit $?
	fi
}

remove_command () {
	if test -n "$continue" && test -e "$splice_file"
	then
		# We must be continuing from a previously failed removal,
		# since once the insertion completed, $splice_file gets
		# removed.
		check_splice_file_action
		git_splice --continue
	else
		# We're either continuing from a previously failed insertion,
		# or this is the first attempt to run this workflow.  Either
		# way, this is the first attempt at the removal phase.
		echo "$action" >"$splice_file"
		cat "$remove_todo" | xargs -t git splice $debug --transplant
	fi
}

valid_branch () {
	case $( git rev-parse --symbolic-full-name "$1" ) in
	refs/heads/*)
		return 0
		;;
	esac

	return 1
}

in_progress () {
	if test -e "$insert_todo"
	then
		reason="$insert_todo exists"
		return 0
	fi

	if test -e "$remove_todo"
	then
		reason="remove_todo exists"
		return 0
	fi

	if test -e "$splice_file" && git splice --in-progress >/dev/null
	then
		reason="splice started by transplant is in progress"
		return 0
	fi

	if test -d "$transplant_dir"
	then
		reason="$transplant_dir exists"
		return 0
	fi

	reason=
	return 1
}

cleanup () {
	aborted=

	if test -e "$insert_todo"
	then
		rm "$insert_todo"
		aborted=y
	fi

	if test -e "$remove_todo"
	then
		rm "$remove_todo"
		aborted=y
	fi

	if test -e "$splice_file" && git splice --in-progress >/dev/null
	then
		git splice --abort
		aborted=y
	fi

	if test -n "$src_branch" && ! on_branch "$src_branch"
	then
		git checkout "$src_branch"
		aborted=y
	fi

	if test -e "$dest_branch_created_file"
	then
		if valid_ref "$dest_branch"
		then
			git branch -D "$dest_branch"
			aborted=y
		fi
	elif test -e "$dest_branch_orig_sha_file"
	then
		orig_dest_sha="$(cat $dest_branch_orig_sha_file)"
		if test $(git rev-parse "$dest_branch") != "$orig_dest_sha"
		then
			git branch -f "$dest_branch" "$orig_dest_sha"
			aborted=y
		fi
	fi

	if test -d "$transplant_dir"
	then
		rm -rf "$transplant_dir"
		aborted=y
	fi
}

transplant_abort () {
	cleanup

	if test -z "$aborted"
	then
		fatal "No transplant in progress"
	fi
}

ensure_transplant_in_progress () {
	if ! in_progress
	then
		fatal "Transplant not in progress"
	fi
}

ensure_transplant_not_in_progress () {
	if in_progress
	then
		in_progress_error "$reason"
	fi
}

parse_opts () {
	ORIG_ARGV=( "$@" )

	while test $# != 0
	do
		: "next argument: $1"
		case "$1" in
		-h|--help)
			usage
			;;
		-v|--version)
			echo "$me $VERSION"
			;;
		-d|--debug)
			debug=--debug
			echo >&2 "#-------------------------------------------------"
			echo >&2 "# Invocation: $0 ${ORIG_ARGV[@]}"
			set -x
			shift
			;;
		--continue)
			continue=yes
			shift
			;;
		--abort)
			abort=yes
			shift
			;;
		--in-progress)
			in_progress=yes
			shift
			;;
		-a|--after)
			after="$2"
			shift 2
			;;
		--after=*)
			after="${1#--after=}"
			shift
			;;
		-n|--new-from)
			new_from="$2"
			shift 2
			;;
		--new-from=*)
			new_from="${1#--new-from=}"
			shift
			;;
		--[a-z]*)
			fatal "Unrecognised option: $1"
			;;
		*)
			break
			;;
		esac
	done

	if echo "$continue$abort$in_progress" | grep -q yesyes
	then
		fatal "You must only select one of --abort, --continue, and --in-progress."
	fi

	if test -n "$after" && test -n "$new_from"
	then
		fatal "You must only select one of --after and --new-from."
	fi

	ARGV=( "$@" )
}

parse_args () {
	if test -n "$abort" || test -n "$continue" || test -n "$rebase_edit"
	then
		return
	fi

	if test $# -ne 2
	then
		fatal "Incorrect number of arguments."
	fi

	range="$1"
	dest_branch="$2"

	validate_range

	mkdir -p "$transplant_dir"

	if ! head_ref >"$src_branch_file"
	then
		cleanup
		fatal "Cannot run $me on detached head"
	fi

	head=$(cat $src_branch_file)
	escaped_head=$(echo "$head" | sed 's,/,\\/,g')

	echo "$range" |
		sed "s/\([^.]\.\.\)$/\1HEAD/;
		     s/\(^\|[^_]\)HEAD/\1${escaped_head}/g" >"$insert_todo"
	cp "$insert_todo" "$remove_todo"

	if test -z "$new_from"
	then
		if ! valid_ref "$dest_branch"
		then
			cleanup
			fatal "Failed to parse $dest_branch"
		fi

		if ! valid_branch "$dest_branch"
		then
			cleanup
			fatal "Destination $dest_branch isn't a branch"
		fi
	else
		if valid_ref "$dest_branch"
		then
			cleanup
			fatal "$dest_branch should not already exist"\
			      "when using --new-from"
		fi
	fi

	for ref in "$after" "$new_from"
	do
		if test -n "$ref" && ! valid_ref "$ref"
		then
			cleanup
			fatal "Failed to parse $ref"
		fi
	done

	echo "$dest_branch" >"$dest_branch_file"
	if test -z "$new_from"
	then
		git rev-parse "$dest_branch" >"$dest_branch_orig_sha_file"
	fi

	if test -n "$after"
	then
		echo "$after" >"$after_file"
	fi
}

validate_range () {
	if ! parsed=( $(git rev-parse "$range" 2>/dev/null) )
	then
		cleanup
		fatal "Failed to parse $range"
	fi

	if [ "${#parsed[@]}" -eq 1 ]
	then
		cleanup
		fatal "TRANSPLANT_RANGE must not be a reference to a single commit."
	fi

	newest=$(git rev-list "$range" | head -n1)
	head=$(head_ref)
	mb=$(git merge-base "$newest" "$head")
	if test "$mb" != "$newest"
	then
		cleanup
		fatal "$newest is in transplant range but not in $head branch"
	fi
}

main "$@"
