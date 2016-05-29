#!/bin/sh
#
# Copyright (c) 2016 Adam Spiers
#

test_description='git transplant

This tests all features of git-transplant.
'

# Useful when debugging with bash; harmless otherwise
PS4="+\${BASH_SOURCE/\$HOME/\~}@\${LINENO}(\${FUNCNAME[0]}): " \
   && export PS4

. ./test-lib.sh

TMP_BRANCH=tmp/splice

#############################################################################
# Setup

for i in one two three
do
	for j in a b
	do
		tag=$i-$j
		test_expect_success "setup $i" "
			echo $i $j >> $i &&
			git add $i &&
			git commit -m \"$i $j\" &&
			git tag $tag"
	done
done
git_dir=$(git rev-parse --git-dir)
latest_tag=$tag

test_expect_success "setup other branch" '
	git checkout -b four one-b &&
	for i in a b c
	do
		echo four $i >> four &&
		git add four &&
		git commit -m "four $i" &&
		git tag "four-$i"
	done &&
	git checkout master
'

test_debug 'git show-ref'
orig_master=$(git rev-parse HEAD)

del_branch () {
	git update-ref -d refs/heads/$1 &&
	echo "deleted $1 branch"
}

del_tmp_branch () {
	del_branch $TMP_BRANCH
}

reset () {
	# First check that tests don't leave a transplant in progress,
	# as they should always do --abort or --continue if necessary.
	# We also expect them to leave the master branch checked out.
	test_transplant_not_in_progress &&
	on_branch master &&
	git reset --hard $latest_tag &&
	git branch -f four four-c &&
	git update-ref -d refs/heads/new &&
	rm -f stdout stderr
}

git_transplant () {
	$test_exp git transplant ${debug:+-d} "$@" >stdout 2>stderr
	ret=$?
	set +x
	if [ -s stdout ]
	then
		echo "------ STDOUT from $test_exp git transplant $* ------"
	fi
	cat stdout
	if [ -s stderr ]
	then
		echo "------ STDERR from $test_exp git transplant $* ------"
		cat stderr
	fi
	echo "------ exit $ret from $test_exp git transplant $* ------"
	if test -n "$trace"
	then
		set -x
	fi
	return $ret
}

test_git_transplant_must_fail () {
	local test_exp=test_must_fail
	git_transplant "$@"
}

head_ref () {
	git symbolic-ref --short -q HEAD
}

on_branch () {
	if test "$(head_ref)" = "$1"
	then
		return 0
	else
		echo "not on $1 branch" >&2
		return 1
	fi
}

valid_ref () {
	if git rev-parse --quiet --verify "$1" >/dev/null
	then
		echo "ref $1 exists"
		return 0
	else
		echo "ref $1 doesn't exist"
		return 1
	fi
}

refs_equal () {
	a=$(git rev-parse "$1")
	b=$(git rev-parse "$2")
	if test "$a" = "$b"
	then
		echo "$1 is same commit as $2"
		return 0
	else
		echo "$1 is different commit to $2 ($a vs. $b)"
		return 1
	fi
}

on_original_master () {
	on_branch master &&
	refs_equal master "$orig_master"
}

test_transplant_in_progress () {
	git transplant --in-progress
}

test_transplant_not_in_progress () {
	test_must_fail git transplant --in-progress &&
	test_git_transplant_must_fail --continue &&
	    grep -q "Transplant not in progress" stderr &&
	    test_debug 'echo "--continue failed as expected - good"' &&
	test_git_transplant_must_fail --abort    &&
	    grep -q "Transplant not in progress" stderr &&
	    test_debug 'echo "--abort failed as expected - good"'
}

#############################################################################
# Invalid arguments

test_expect_success 'empty command line' '
	test_git_transplant_must_fail &&
	cat stderr &&
	grep "Incorrect number of arguments" stderr
'

test_expect_success 'only one argument' '
	test_git_transplant_must_fail foo &&
	grep "Incorrect number of arguments" stderr
'

test_expect_success 'too many arguments' '
	test_git_transplant_must_fail a b c &&
	grep "Incorrect number of arguments" stderr
'

test_expect_success 'invalid start of commit range' '
	test_git_transplant_must_fail a..two-b four &&
	grep "Failed to parse a..two-b" stderr
'

test_expect_success 'invalid end of commit range' '
	test_git_transplant_must_fail two-a^..five four &&
	grep "Failed to parse two-a^..five" stderr
'

test_expect_success 'single commitish instead of transplant range' '
	test_git_transplant_must_fail two-a four &&
	grep "TRANSPLANT_RANGE must not be a reference to a single commit" stderr
'

test_expect_success 'invalid destination branch' '
	test_git_transplant_must_fail two-a^..two-b blah &&
	grep "Failed to parse blah" stderr
'

test_expect_success "destination wasn't a branch" '
	test_git_transplant_must_fail two-a^..two-b four^ &&
	grep "Destination four^ isn'\''t a branch" stderr
'

test_expect_success "invalid option" '
	test_git_transplant_must_fail --blah two-a^..two-b four &&
	grep "Unrecognised option: --blah" stderr
'

for sep in ' ' '='
do
	test_expect_success "invalid --after${sep}ref" "
		test_git_transplant_must_fail \
			--after${sep}blah two-a^..two-b four &&
		grep 'Failed to parse blah' stderr
	"

	test_expect_success "invalid --new-from${sep}ref" "
		test_git_transplant_must_fail \
			--new-from${sep}blah two-a^..two-b new &&
		test_debug 'cat stderr' &&
		grep 'Failed to parse blah' stderr
	"

	test_expect_success "existing dest branch with --new-from${sep}ref" "
		test_git_transplant_must_fail \
			--new-from${sep}blah two-a^..two-b four &&
		test_debug 'cat stderr' &&
		grep 'four should not already exist when using --new-from' stderr
	"
done

test_only_one_option () {
	test_transplant_not_in_progress &&
	test_git_transplant_must_fail $1 &&
	grep "You must only select one of $2" stderr &&
	test_transplant_not_in_progress
}

for combo in \
	'--abort --continue' \
	'--continue --abort' \
	'--abort --in-progress' \
	'--in-progress --abort' \
	'--continue --in-progress' \
	'--in-progress --continue'
do
	test_expect_success "$combo" "
		test_only_one_option \"$combo\" \"--abort, --continue, and --in-progress\"
	"
done

for combo in \
	'--after foo --new-from bar' \
	'--new-from bar --after foo'
do
	test_expect_success "$combo" "
		test_only_one_option \"$combo\" \"--after and --new-from\"
	"
done

#############################################################################
# Invalid initial state

test_expect_success "checkout $TMP_BRANCH; ensure transplant won't start" "
	test_when_finished 'git checkout master; del_tmp_branch' &&
	reset &&
	git checkout -b $TMP_BRANCH &&
	test_git_transplant_must_fail two-b^! four &&
	grep 'fatal: $TMP_BRANCH branch exists, but no splice in progress' stderr &&
	git checkout master &&
	del_tmp_branch &&
	test_transplant_not_in_progress
"

test_expect_success "create $TMP_BRANCH; ensure transplant won't start" "
	test_when_finished 'del_tmp_branch' &&
	reset &&
	git branch $TMP_BRANCH master &&
	test_git_transplant_must_fail two-b^! four &&
	grep 'fatal: $TMP_BRANCH branch exists, but no splice in progress' stderr &&
	on_original_master &&
	del_tmp_branch &&
	test_transplant_not_in_progress
"

test_expect_success "start cherry-pick with conflicts; ensure transplant won't start" '
	test_when_finished "git cherry-pick --abort" &&
	reset &&
	test_must_fail git cherry-pick four-b >stdout 2>stderr &&
	grep "error: could not apply .* four b" stderr &&
	test_git_transplant_must_fail two-b^! four &&
	grep "Can'\''t start git transplant when there is a cherry-pick in progress" stderr &&
	on_original_master &&
	del_tmp_branch &&
	test_transplant_not_in_progress
'

test_expect_success "start rebase with conflicts; ensure transplant won't start" '
	test_when_finished "git rebase --abort" &&
	reset &&
	test_must_fail git rebase --onto one-b two-a >stdout 2>stderr &&
	grep "CONFLICT" stdout &&
	grep "error: could not apply .* two b" stderr &&
	test_git_transplant_must_fail two-b^! four &&
	grep "Can'\''t start git transplant when there is a rebase in progress" stderr &&
	del_tmp_branch &&
	test_transplant_not_in_progress
'

test_expect_success 'cause conflict; ensure not re-entrant' '
	test_when_finished "
		git_transplant --abort &&
		test_transplant_not_in_progress
	" &&
	reset &&
	test_git_transplant_must_fail two-a^! four &&
	test_transplant_in_progress &&
	test_git_transplant_must_fail two-a^! four &&
	grep "git transplant already in progress; please complete it, or run" stderr &&
	grep "git transplant --abort" stderr &&
	test_transplant_in_progress
'

test_expect_success 'dirty working tree would prevent checkout of dest branch' '
	reset &&
	echo dirty >>two &&
	test_git_transplant_must_fail two-b^! four &&
	grep "Cannot transplant: You have unstaged changes" stderr &&
	grep "Please commit or stash them" stderr &&
	on_original_master &&
	grep dirty two &&
	test_transplant_not_in_progress
'

test_expect_success "dirty working tree would prevent final removal rebase" '
	reset &&
	echo dirty >>one &&
	test_git_transplant_must_fail two-a^..two-b four &&
	grep "Cannot transplant: You have unstaged changes" stderr &&
	grep "Please commit or stash them" stderr &&
	on_original_master &&
	grep dirty one &&
	test_transplant_not_in_progress
'
test_expect_success "transplanting commits outside current branch fails" '
	reset &&
	test_git_transplant_must_fail -d --new-from=one-b four-a^..four-c new &&
	grep "^fatal: .* is in transplant range but not in master branch" stderr &&
	on_original_master &&
	test_transplant_not_in_progress
'

#############################################################################
# Valid transplants

transplant_two_to () {
	dest_branch="$1"
	shift
	reset &&
	echo git transplant "$@" two-a^..two-b "$dest_branch" &&
	git_transplant "$@" two-a^..two-b "$dest_branch" &&
	on_branch master &&
	git show ${dest_branch}:two | grep "two a" &&
	git show ${dest_branch}:two | grep "two b" &&
	! test -e two &&
	test_transplant_not_in_progress &&
	branch_history master | grep "three b, three a, one b, one a"
}

branch_history () {
	git log --format=format:%s, "$@" | xargs
}

test_expect_success 'transplant a range' '
	transplant_two_to four &&
	branch_history four | grep "two b, two a, four c,"
'

for sep in ' ' '='
do
	test_expect_success "transplant range inside branch (--after${sep}ref)" "
		transplant_two_to four --after${sep}four-a &&
		branch_history four |
			grep 'four c, four b, two b, two a, four a'
	"

	for from in four four-a
	do
		from_arg="--new-from$sep$from"
		test="transplant range onto new branch ($from_arg)"
		new_history='two b, two a'
		case "$from" in
		four)
			new_history="$new_history, four c, four b, four a"
			;;
		four-a)
			new_history="$new_history, four a"
			;;
		esac
		test_expect_success "$test" "
			transplant_two_to new $from_arg &&
			branch_history four |
				grep 'four c, four b, four a' &&
			branch_history new |
				grep '$new_history'
		"
	done
done

test_expect_success 'transplant HEAD^! (three-b) to three-bee' '
	reset &&
	git_transplant --new-from three-a HEAD^! three-bee &&
	on_branch master &&
	branch_history master |
		grep "three a, two b, two a, one b, one a" &&
	branch_history three-bee |
		grep "three b, three a, two b, two a, one b, one a" &&
	test_transplant_not_in_progress &&
	del_branch three-bee
'

test_expect_success 'transplant HEAD~2..HEAD (three a and b) to new-three' '
	reset &&
	git_transplant --new-from two-b HEAD~2..HEAD new-three &&
	on_branch master &&
	branch_history master |
		grep "two b, two a, one b, one a" &&
	branch_history new-three |
		grep "three b, three a, two b, two a, one b, one a" &&
	test_transplant_not_in_progress &&
	del_branch new-three
'

test_expect_success 'transplant HEAD~2..HEAD (three a and b) to new-three with / in branch name' '
	reset &&
	git checkout -b one/two/three &&
	git_transplant --new-from two-b HEAD~2..HEAD new-three &&
	on_branch one/two/three &&
	branch_history master |
		grep "two b, two a, one b, one a" &&
	branch_history new-three |
		grep "three b, three a, two b, two a, one b, one a" &&
	test_transplant_not_in_progress &&
	git checkout master &&
	del_branch new-three &&
	del_branch one/two/three
'

test_expect_success 'transplant HEAD~2.. (three a and b) to new-three' '
	reset &&
	git_transplant --new-from two-b HEAD~2.. new-three &&
	on_branch master &&
	branch_history master |
		grep "two b, two a, one b, one a" &&
	branch_history new-three |
		grep "three b, three a, two b, two a, one b, one a" &&
	test_transplant_not_in_progress
'

#############################################################################
# Handling conflicts

test_expect_success 'transplant commit causing insertion conflict; abort' '
	reset &&
	test_git_transplant_must_fail two-b^! four &&
	test_debug "echo STDOUT; cat stdout; echo ----" &&
	test_debug "echo STDERR; cat stderr; echo ----" &&
	grep "CONFLICT.*: two deleted in HEAD and modified in .* (two b)" stdout &&
	grep "error: could not apply .* two b" stderr &&
	grep "When you have resolved this problem, run \"git transplant --continue\"" stderr &&
	grep "or run \"git transplant --abort\"" stderr &&
	git_transplant --abort &&
	on_original_master &&
	refs_equal four four-c &&
	test_transplant_not_in_progress
'

test_expect_success 'transplant commit to new causing insertion conflict; abort' '
	reset &&
	test_git_transplant_must_fail -n four two-b^! four-two-b &&
	test_debug "echo STDOUT; cat stdout; echo ----" &&
	test_debug "echo STDERR; cat stderr; echo ----" &&
	grep "CONFLICT.*: two deleted in HEAD and modified in .* (two b)" stdout &&
	grep "error: could not apply .* two b" stderr &&
	grep "When you have resolved this problem, run \"git transplant --continue\"" stderr &&
	grep "or run \"git transplant --abort\"" stderr &&
	git_transplant --abort &&
	on_original_master &&
	refs_equal four four-c &&
	! valid_ref four-two-b &&
	test_transplant_not_in_progress
'

test_expect_success 'transplant commit causing removal conflict; abort' '
	reset &&
	test_git_transplant_must_fail two-a^! four &&
	test_debug "echo STDOUT; cat stdout; echo ----" &&
	test_debug "echo STDERR; cat stderr; echo ----" &&
	grep "error: could not apply .* two b" stdout &&
	grep "CONFLICT .*: two deleted in HEAD and modified in .* (two b)" stdout &&
	grep "When you have resolved this problem, run \"git transplant --continue\"" stderr &&
	grep "or run \"git transplant --abort\"" stderr &&
	git_transplant --abort &&
	on_original_master &&
	refs_equal four four-c &&
	test_transplant_not_in_progress
'

test_expect_success 'transplant commit causing insertion conflict; continue' '
	reset &&
	test_git_transplant_must_fail two-b^! four &&
	test_debug "echo STDOUT; cat stdout; echo ----" &&
	test_debug "echo STDERR; cat stderr; echo ----" &&
	grep "CONFLICT.*: two deleted in HEAD and modified in .* (two b)" stdout &&
	grep "error: could not apply .* two b" stderr &&
	grep "When you have resolved this problem, run \"git transplant --continue\"" stderr &&
	grep "or run \"git transplant --abort\"" stderr &&
	echo "two b resolved" > two &&
	git add two &&
	git_transplant --continue &&
	test_transplant_not_in_progress &&
	! refs_equal four four-c &&
	git show four:two | grep "two b resolved" &&
	branch_history master |
		grep "three b, three a, two a, one b, one a" &&
	branch_history four |
		grep "two b, four c, four b, four a, one b, one a"
'

test_expect_success 'transplant commit causing removal conflict; continue' '
	reset &&
	test_git_transplant_must_fail two-a^! four &&
	test_debug "echo STDOUT; cat stdout; echo ----" &&
	test_debug "echo STDERR; cat stderr; echo ----" &&
	grep "error: could not apply .* two b" stdout &&
	grep "CONFLICT .*: two deleted in HEAD and modified in .* (two b)" stdout &&
	grep "When you have resolved this problem, run \"git transplant --continue\"" stderr &&
	grep "or run \"git transplant --abort\"" stderr &&
	echo "two b resolved" >two &&
	git add two &&
	git_transplant --continue &&
	test_transplant_not_in_progress &&
	! refs_equal four four-c &&
	git show four:two | grep "two a" &&
	grep "two b resolved" two &&
	branch_history master |
		grep "three b, three a, two b, one b, one a" &&
	branch_history four |
		grep "two a, four c, four b, four a, one b, one a" &&
	test_transplant_not_in_progress
'

test_done
