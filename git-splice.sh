#!/bin/bash
#
# git-splice - splice commits into/out of current branch
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
USAGE="<insertion point> <cherry pick range>
   or: $dashless <insertion point> -- <cherry pick range args ...>
   or: $dashless [-r|--root] <remove range> [<cherry pick range>]
   or: $dashless [-r|--root] <remove range args> ... -- <cherry pick range args ...>
   or: $dashless (--abort | --continue | --in-progress)"
LONG_USAGE=\
'    -h, --help     Show this help and exit
     -r, root      Treat (each) removal range argument as a commit-ish, and
                   remove all its ancestors.
    --abort        Abort an in-progress splice
    --continue     Continue an in-progress splice
    --in-progress  Exit 0 if and only if a splice is in progress'

OPTIONS_SPEC=
. git-sh-setup
. git-splice--lib

# Useful when debugging with bash; harmless otherwise
PS4="+\${BASH_SOURCE/\$HOME/\~}@\${LINENO}(\${FUNCNAME[0]}): " \
   && export PS4

me=$(basename $0)
git_dir=$(git rev-parse --git-dir) || exit 1
splice_dir="$git_dir/splice"
base_file="$splice_dir/base"
branch_file="$splice_dir/branch"
insert_todo="$splice_dir/insert-todo"
remove_todo="$splice_dir/remove-todo"
rebase_exit="$splice_dir/rebase-exit"
rebase_cancelled="$splice_dir/rebase-cancelled"
TMP_BRANCH="tmp/splice"
workflow=splice

main () {
	parse_opts "$@"

	if test -n "$in_progress"
	then
		if in_progress
		then
			echo "Splice in progress: $reason"
			exit 0
		else
			echo "Splice not in progress"
			exit 1
		fi
	fi

	if test -n "$abort" || test -n "$continue" || test -n "$rebase_edit"
	then
		ensure_splice_in_progress
	else
		# Needs to happen before parse_args(), otherwise the in-flight
		# files will already exist.
		ensure_splice_not_in_progress
	fi

	parse_args "${ARGV[@]}"

	if test -n "$rebase_edit"
	then
		# We're being invoked by git rebase as the rebase todo list editor,
		# rather than by the user.  This mode is for internal use only.
		rebase_edit
		return
	fi

	if test -n "$abort"
	then
		splice_abort
		return
	fi

	# Handle both normal execution and --continue
	splice
}

prepare_tmp_branch () {
	if valid_ref "$TMP_BRANCH"
	then
		if test -z "$continue"
		then
			die "BUG: $TMP_BRANCH exists but no --continue"
		fi

		if ! on_tmp_branch
		then
			: "Presumably on a detached head in the middle of a rebase"
		fi
	else
		if removing_root
		then
			echo git checkout -q --orphan "$TMP_BRANCH"
			git checkout -q --orphan "$TMP_BRANCH"
			git reset --hard
		else
			echo git checkout -q -B "$TMP_BRANCH" "$base"
			git checkout -q -B "$TMP_BRANCH" "$base"
		fi
	fi
}

do_cherry_picks () {
	if cherry_pick_active
	then
		if ! git cherry-pick --continue
		then
			error_and_pause "git cherry-pick --continue failed!"
		fi
	else
		reason="cat $insert_todo | xargs git cherry-pick"
		if ! cat $insert_todo | xargs -t git cherry-pick
		then
			error_and_pause "git cherry-pick failed!"
		fi
		rm "$insert_todo"
	fi
}

do_rebase () {
	if rebase_active
	then
		args=( --continue )
	elif removing_root
	then
		args=( -i --root "$branch" )
	else
		args=( -i --onto "$TMP_BRANCH" "$base" "$branch" )
	fi

	# We make git rebase -i use a special internal-only invocation of
	# git-splice which non-interactively edits the temporary
	# $rebase_todo file.
	export GIT_SEQUENCE_EDITOR="$0 $debug --rebase-edit"

	echo git rebase "${args[@]}"
	# git rebase can output messages on STDOUT or STDERR depending
	# on whether verbose is enabled.  Either way we want to catch
	# references to "git rebase --continue" / "git rebase --abort"
	# and tweak them to refer to git splice instead.
	#
	# To achieve that, we filter both STDOUT and STDERR through pipes,
	# using a clever technique explained here:
	# http://wiki.bash-hackers.org/howto/redirection_tutorial
	rm -f "$rebase_exit"
	{
		{
			{
				git rebase "${args[@]}" 3>&-;
				echo $? >"$rebase_exit"
			} |
				tweak_rebase_error 2>&3 3>&-
		} 2>&1 >&4 4>&- |
			tweak_rebase_error 3>&- 4>&-
	} 3>&2 4>&1
	rebase_exitcode="$(cat $rebase_exit)"
	rm -f "$rebase_exit"
	if test "$rebase_exitcode" != 0
	then
		if test -e "$rebase_cancelled"
		then
			: "happens if there were no commits (left) to rebase"
			git checkout "$branch"
			git reset --hard "$TMP_BRANCH"
			rm "$rebase_cancelled"
		else
			error_and_pause "git rebase ${args[*]} failed!"
		fi
	fi
}

splice () {
	base="$(cat $base_file)"
	branch="$(cat $branch_file)"

	validate_base

	if removing_root
	then
		if test -s "$insert_todo"
		then
			# If we're creating a new root commit, it will either come
			# by cherry-picking onto a new orphaned $TMP_BRANCH, if we
			# have any cherry-picking to do:
			prepare_tmp_branch
		else
			# or it will come via rebase --root, in which case we don't
			# need a temporary branch.
			no_tmp_branch=y
		fi
	else
		prepare_tmp_branch
	fi

	if test -s "$insert_todo"
	then
		do_cherry_picks
	fi

	if ! removing_root && test "$base" = "$branch"
	then
		echo git checkout -B "$branch" "$TMP_BRANCH"
		git checkout -B "$branch" "$TMP_BRANCH"
	else
		do_rebase
	fi

	if test -z "$no_tmp_branch"
	then
		git branch -d "$TMP_BRANCH"
	fi
	rm -rf "$splice_dir"
}

tweak_rebase_error () {
	grep -v 'When you have resolved this problem, run "git rebase --continue"\.' |
		sed -e 's/git rebase \(--continue\|--abort\)/git splice \1/g'
}

# Returns true (0) iff the arguments passed explicitly describe a
# range of commits (e.g. A..B).  Note that this deliberately returns
# false when fed a single commit-ish A, even though a commit-ish
# technically describes a range covering A and all its ancestors.
# This is used to infer whether the user intended this commit to be
# interpreted as an insertion point or a removal range, when it is not
# made clear by the use of --root or a particular combination of
# arguments on ARGV.
valid_commit_range () {
	if ! parsed=( $(git rev-parse "$@" 2>/dev/null) )
	then
		cleanup
		fatal "Failed to parse commit range $1"
	fi
	test "${#parsed[@]}" -gt 1
}

removing_root () {
	test "$base" = 'ROOT'
}

validate_base () {
	if test -z "$base"
	then
		die "BUG: base should not be empty"
	fi

	if removing_root
	then
		: "We're removing the root commit"
		return
	fi

	if ! valid_ref "$base"
	then
		cleanup
		die "BUG: base commit $base was not valid"
	fi
}

error_and_pause () {
	warn "$*"
	warn "When you have resolved this problem, run \"git $workflow --continue\","
	warn "or run \"git $workflow --abort\" to abandon the splice."
	exit 1
}

in_progress () {
	if test -e "$insert_todo"
	then
		reason="$insert_todo exists"
		return 0
	fi

	if test -e "$remove_todo"
	then
		reason="$remove_todo exists"
		return 0
	fi

	if test -d "$splice_dir"
	then
		reason="$splice_dir exists"
		return 0
	fi

	if on_tmp_branch
	then
		reason="on $TMP_BRANCH branch"
		return 0
	fi

	reason=
	return 1
}

cleanup () {
	aborted=

	if test -e "$insert_todo"
	then
		# Can we be sure that the in-flight cherry-pick was started by
		# git splice?  Probably, because otherwise
		# ensure_cherry_pick_not_in_progress should have prevented us
		# from reaching this point in the code.
		if cherry_pick_active
		then
			git cherry-pick --abort
		fi

		rm "$insert_todo"
		aborted=y
	fi

	if test -e "$remove_todo"
	then
		if rebase_active
		then
			git rebase --abort
		fi

		rm "$remove_todo"
		aborted=y
	fi

	if valid_ref "$TMP_BRANCH"
	then
		if on_tmp_branch
		then
			git checkout "$(cat $branch_file)"
		fi

		git branch -d "$TMP_BRANCH"
		aborted=y
	fi

	if test -d "$splice_dir"
	then
		rm -rf "$splice_dir"
		aborted=y
	fi
}

splice_abort () {
	cleanup

	if test -z "$aborted"
	then
		fatal "No splice in progress"
	fi
}

on_tmp_branch () {
	on_branch "$TMP_BRANCH"
}

ensure_splice_in_progress () {
	if ! in_progress
	then
		fatal "Splice not in progress"
	fi
}

ensure_splice_not_in_progress () {
	for file in "$insert_todo" "$remove_todo"
	do
		if test -e "$file"
		then
			in_progress_error "$file already exists."
		fi
	done

	ensure_cherry_pick_not_in_progress
	ensure_rebase_not_in_progress

	if on_tmp_branch
	then
		fatal "On $TMP_BRANCH branch, but no splice in progress."\
		    "Try switching to another branch first."
	fi

	if valid_ref "$TMP_BRANCH"
	then
		fatal "$TMP_BRANCH branch exists, but no splice in"\
		    "progress. Try deleting $TMP_BRANCH first."
	fi
}

rebase_edit () {
	if ! test -e "$rebase_todo"
	then
		die "BUG: $me invoked in rebase edit mode,"\
		    "but $rebase_todo was missing"
	fi

	if test -e "$remove_todo"
	then
		sed -i 's/^\([0-9a-f]\+\)$/^pick \1/' "$remove_todo"
		grep -v -f "$remove_todo" "$rebase_todo" >"$rebase_todo".new
		if test -n "$debug"
		then
			set +x
			echo -e "-----------------------------------"
			echo "$rebase_todo"
			cat "$rebase_todo"
			echo -e "-----------------------------------"
			echo "$remove_todo"
			cat "$remove_todo"
			echo -e "-----------------------------------"
			echo "$rebase_todo.new"
			cat "$rebase_todo.new"
			set -x
		fi
		mv "$rebase_todo".new "$rebase_todo"
	fi

	if ! grep '^ *[a-z]' "$rebase_todo"
	then
		echo "Nothing left to rebase; cancelling."
		>"$rebase_todo"
		touch "$rebase_cancelled"
	fi
}

parse_opts () {
	ORIG_ARGV=( "$@" )
	while test $# != 0
	do
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
		-r|--root)
			root=yes
			shift
			;;
		# for internal use only
		--rebase-edit)
			rebase_edit=yes
			rebase_todo="$2"
			shift 2
                ;;
            --transplant)
                workflow=transplant
                shift
			;;
		*)
			break
			;;
		esac
	done

	if echo "$continue$abort$in_progress" | grep -q yesyes
	then
		fatal "You must only select one of --abort, --continue,"\
		    "and --in-progress."
	fi

	ARGV=( "$@" )
}

detect_remove_range_or_insertion_point () {
	# Figure out whether the first parameter is a remove range
	# or insertion point.
	if test -z "$root"
	then
		if valid_commit_range "$@"
		then
			: "$1 must be a removal range"
			remove_range=( "$@" )
		else
			: "$* must be an insertion point"
			insertion_point="$@"
		fi
	else
		# The user has explicitly requested a removal of the
		# commit-ish and all its ancestors.
		remove_range=( "$@" )
	fi
}

parse_args () {
	if test -n "$abort" || test -n "$continue" ||
			test -n "$in_progress" || test -n "$rebase_edit"
	then
		return
	fi

	count=$#
	for word in "$@"
	do
		if test "$word" = '--'
		then
			multi_word=yes
			count=$(( $count - 1 ))
			break
		fi
	done

	if test $count -eq 0
	then
		fatal "You must specify at least one range to splice."
	fi

	if test -z "$multi_word"
	then
		# No "--" argument present, so the number of arguments is significant.
		if test $# -eq 1
		then
			if test -z "$root"
			then
				# In this invocation form, $1 must be a removal range,
				# because nothing has been given to cherry-pick.
				if ! valid_commit_range "$1"
				then
					fatal "$1 is not a valid removal range"
				fi
			else
				# The user has explicitly requested a removal of the
				# commit-ish and all its ancestors.
				if ! valid_ref "$1"
				then
					fatal "$1 is not a valid removal commit-ish"
				fi
			fi
			remove_range=( "$1" )
		elif test $# -eq 2
		then
			insert_range=( "$2" )
			detect_remove_range_or_insertion_point "$1"
		elif test $# -ge 2
		then
			fatal "Use of multiple words in the removal or insertion"\
			    "ranges requires the -- separator"
		fi
	else
		# "--" argument is present, so split
		remove_range_or_insertion_base=()
		for word in "$@"
		do
			if test "$word" = '--'
			then
				shift
				insert_range=( "$@" )
				break
			fi
			remove_range_or_insertion_base+=( "$word" )
			shift
		done

		detect_remove_range_or_insertion_point \
			"${remove_range_or_insertion_base[@]}"
	fi

	mkdir -p "$splice_dir"

	if ! head_ref >"$branch_file"
	then
		rm "$branch_file"
		fatal "Cannot run $me on detached head"
	fi

	if [ "${#remove_range[@]}" -gt 0 ]
	then
		# In this case we already know it's a range
		: "removing range ${remove_range[@]}"
		check_no_merge_commits "Removing" "${remove_range[@]}"
		populate_remove_todo "${remove_range[@]}"
		populate_base_file "${remove_range[@]}"
	elif test -n "$insertion_point"
	then
		echo "$insertion_point" >"$base_file"
	else
		die "BUG: didn't get removal range or insertion point"
	fi

	if [ "${#insert_range[@]}" -gt 0 ]
	then
		if ! valid_commit_range "${insert_range[@]}"
		then
			cleanup
			fatal "Failed to parse ${insert_range[*]} as insertion range"
		fi

		check_no_merge_commits "Inserting" "${insert_range[@]}"

		if [ "${#insert_range[@]}" -eq 1 ]
		then
			echo "${insert_range[@]}" >"$insert_todo"
		else
			git rev-list --reverse "${insert_range[@]}" >"$insert_todo"
		fi
	fi
}

check_no_merge_commits () {
	action="$1"
	shift
	if git rev-list --min-parents=2 -n1 "$@" | grep -q .
	then
		cleanup
		fatal "$action merge commits is not supported"
	fi
}

populate_remove_todo () {
	git rev-list --abbrev-commit "$@" >"$remove_todo"
	if ! test -s "$remove_todo"
	then
		cleanup
		fatal "No commits found in removal range $*"
	fi
	newest=$(head -n1 "$remove_todo")
	newest=$(git rev-parse "$newest") # unabbreviate for comparison below
	head=$(head_ref)
	mb=$(git merge-base "$newest" "$head")
	if test "$mb" != "$newest"
	then
		cleanup
		fatal "$newest is in removal range but not in $head branch"
	fi
}

populate_base_file () {
	earliest=$(tail -n1 "$remove_todo")
	echo "Earliest commit in $@ is $earliest"
	if git rev-list --min-parents=1 -n1 "${earliest}" | grep -q .
	then
		# Earliest in removal range has a parent
		echo "${earliest}^" >"$base_file"
	else
		echo "ROOT" >"$base_file"
	fi
}

main "$@"
