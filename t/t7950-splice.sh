#!/bin/sh
#
# Copyright (c) 2016 Adam Spiers
#

test_description='git splice

This tests all features of git-splice.
'

# Useful when debugging with bash; harmless otherwise
# PS4="+\${BASH_SOURCE/\$HOME/\~}@\${LINENO}(\${FUNCNAME[0]}): " \
#    && export PS4

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
git_dir=`git rev-parse --git-dir`
latest_tag=$tag

setup_other_branch () {
	branch="$1" base="$2"
	shift 2
	git checkout -b $branch $base &&
	for i in "$@"
	do
		echo $branch $i >> $branch &&
		git add $branch &&
		git commit -m "$branch $i" &&
		git tag "$branch-$i"
	done
}

test_expect_success "setup four branch" '
	setup_other_branch four one-b a b c &&
	git checkout master
'

test_debug 'git show-ref'

del_tmp_branch () {
	git update-ref -d refs/heads/$TMP_BRANCH
}

reset () {
	# First check that tests don't leave a splice in progress,
	# as they should always do --abort or --continue if necessary
	test_splice_not_in_progress &&
	on_branch master &&
	git reset --hard $latest_tag &&
	del_tmp_branch &&
	rm -f stdout stderr
}

git_splice () {
	$test_exp git splice ${debug:+-d} "$@" >stdout 2>stderr
	ret=$?
	# set +x
	# if [ -s stdout ]
	# then
	# 	echo "====== STDOUT from $test_exp git splice $* ======"
	# fi
	# cat stdout
	# if [ -s stderr ]
	# then
	# 	echo "------ STDERR from $test_exp git splice $* ------"
	# 	cat stderr
	# fi
	# echo "====== exit $ret from $test_exp git splice $* ======"
	# if test -n "$trace"
	# then
	# 	set -x
	# fi
	return $ret
}

test_git_splice_must_fail () {
	local test_exp=test_must_fail
	git_splice "$@"
}

test_splice_in_progress () {
	git splice --in-progress
}

head_ref () {
	git symbolic-ref --short -q HEAD
}

on_branch () {
	if test "`head_ref`" = "$1"
	then
		return 0
	else
		echo "not on $1 branch" >&2
		return 1
	fi
}

test_splice_not_in_progress () {
	test_must_fail git splice --in-progress &&
	test_git_splice_must_fail --continue &&
		grep -q "Splice not in progress" stderr &&
		test_debug 'echo "--continue failed as expected - good"' &&
	test_git_splice_must_fail --abort    &&
		grep -q "Splice not in progress" stderr &&
		test_debug 'echo "--abort failed as expected - good"'
}

#############################################################################
# Invalid arguments

test_expect_success 'empty command line' '
	test_git_splice_must_fail &&
	grep "You must specify at least one range to splice" stderr
'

test_expect_success 'too many arguments' '
	test_git_splice_must_fail a b c &&
	grep "Use of multiple words in the removal or insertion ranges requires the -- separator" stderr
'

test_only_one_option () {
	test_splice_not_in_progress &&
	test_git_splice_must_fail "$@" &&
	grep "You must only select one of --abort, --continue, and --in-progress" stderr &&
	test_splice_not_in_progress
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
		test_only_one_option $combo
	"
done

test_expect_success 'insertion point without insertion range' '
	test_git_splice_must_fail one &&
	grep "fatal: one is not a valid removal range" stderr &&
	test_splice_not_in_progress
'

test_failed_to_parse_removal_spec () {
	test_git_splice_must_fail "$@" &&
	grep "fatal: Failed to parse commit range $*" stderr &&
	test_splice_not_in_progress
}

test_expect_success 'remove invalid single commit' '
	test_failed_to_parse_removal_spec five
'

test_expect_success 'remove range with invalid start' '
	test_failed_to_parse_removal_spec five..two-b
'

test_expect_success 'remove range with invalid end' '
	test_failed_to_parse_removal_spec two-b..five
'

test_expect_success 'empty removal range' '
	test_git_splice_must_fail two-a..two-a &&
	grep "^fatal: No commits found in removal range two-a..two-a" stderr &&
	test_splice_not_in_progress
'

#############################################################################
# Invalid initial state

test_expect_success "checkout $TMP_BRANCH; ensure splice won't start" "
	test_when_finished 'git checkout master; del_tmp_branch' &&
	reset &&
	git checkout -b $TMP_BRANCH &&
	test_git_splice_must_fail two-b^! &&
	grep 'fatal: On $TMP_BRANCH branch, but no splice in progress' stderr &&
	git checkout master &&
	del_tmp_branch &&
	test_splice_not_in_progress
"

test_expect_success "create $TMP_BRANCH; ensure splice won't start" "
	test_when_finished 'del_tmp_branch' &&
	reset &&
	git branch $TMP_BRANCH master &&
	test_git_splice_must_fail two-b^! &&
	grep '$TMP_BRANCH branch exists, but no splice in progress' stderr &&
	del_tmp_branch &&
	test_splice_not_in_progress
"

test_expect_success "start cherry-pick with conflicts; ensure splice won't start" '
	test_when_finished "git cherry-pick --abort" &&
	reset &&
	test_must_fail git cherry-pick four-b >stdout 2>stderr &&
	grep "error: could not apply .* four b" stderr &&
	test_git_splice_must_fail two-b^! &&
	grep "Can'\''t start git splice when there is a cherry-pick in progress" stderr &&
	test_splice_not_in_progress
'

test_expect_success "start rebase with conflicts; ensure splice won't start" '
	test_when_finished "git rebase --abort" &&
	reset &&
	test_must_fail git rebase --onto one-b two-a >stdout 2>stderr &&
	grep "CONFLICT" stdout &&
	grep "error: could not apply .* two b" stderr &&
	test_git_splice_must_fail two-b^! &&
	grep "Can'\''t start git splice when there is a rebase in progress" stderr &&
	test_splice_not_in_progress
'

test_expect_success 'cause conflict; ensure not re-entrant' '
	test_when_finished "
		git_splice --abort &&
		test_splice_not_in_progress
	" &&
	reset &&
	test_git_splice_must_fail two-a^! &&
	test_splice_in_progress &&
	test_git_splice_must_fail two-a^! &&
	grep "git splice already in progress; please complete it, or run" stderr &&
	grep "git splice --abort" stderr &&
	test_splice_in_progress
'

#############################################################################
# Removing a single commit

test_remove_two_b () {
	reset &&
	git_splice two-b^! "$@" &&
	grep "one b"   one   &&
	grep "three b" three &&
	grep "two a"   two   &&
	! grep "two b" two   &&
	test_splice_not_in_progress
}

test_expect_success 'remove single commit' '
	test_remove_two_b
'

test_expect_success 'remove single commit with --' '
	test_remove_two_b --
'

test_expect_success 'remove single commit causing conflict; abort' '
	reset &&
	test_git_splice_must_fail two-a^! &&
	grep "Could not apply .* two b" stdout stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	git_splice --abort &&
	test_splice_not_in_progress
'

test_expect_success 'remove single commit causing conflict; fix; continue' '
	reset &&
	test_git_splice_must_fail two-a^! &&
	grep "Could not apply .* two b" stdout stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	echo two merged >two &&
	git add two &&
	git_splice --continue &&
	grep "two merged" two &&
	grep "three b" three &&
	test_splice_not_in_progress
'

test_expect_success 'remove root commit' '
	# We have to remove one-b first, in order to avoid conflicts when
	# we remove one-a.
	reset &&
	git_splice one-b^! &&
	! grep "one b" one &&
	git_splice --root one-a &&
	! test -e one &&
	grep "three b" three &&
	test_splice_not_in_progress
'

test_expect_success 'remove root commit causing conflict; abort' '
	reset &&
	test_git_splice_must_fail --root one-a &&
	grep "Could not apply .* one b" stdout stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	git_splice --abort &&
	test_splice_not_in_progress
'

test_expect_success 'remove root commit causing conflict; fix; continue' '
	reset &&
	test_git_splice_must_fail --root one-a &&
	grep "Could not apply .* one b" stdout stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	echo one merged >one &&
	git add one &&
	git_splice --continue &&
	grep "one merged" one &&
	grep "three b" three &&
	test_splice_not_in_progress
'

#############################################################################
# Removing a range of commits

test_remove_range_of_commits () {
	reset &&
	git_splice one-b..two-b "$@" &&
	grep "one b"   one   &&
	grep "three b" three &&
	! test -e two        &&
	test_splice_not_in_progress
}

test_expect_success 'remove range of commits' '
	test_remove_range_of_commits
'

test_expect_success 'remove range of commits with --' '
	test_remove_range_of_commits --
'

test_expect_success 'remove commit from branch tip' '
	reset &&
	git_splice HEAD^! &&
	test `git rev-parse HEAD` = `git rev-parse three-a` &&
	test_splice_not_in_progress
'

test_expect_success 'remove commits from branch tip' '
	reset &&
	git_splice HEAD~3..HEAD &&
	test `git rev-parse HEAD` = `git rev-parse two-a` &&
	test_splice_not_in_progress
'

test_expect_success 'remove range of commits starting at root' '
	reset &&
	git_splice --root one-b &&
	! test -e one &&
	grep "three b" three &&
	test_splice_not_in_progress
'

test_expect_success 'remove range of commits starting at root' '
	reset &&
	git_splice --root one-b -- &&
	! test -e one &&
	test_splice_not_in_progress
'

test_expect_success 'remove range of commits outside branch' '
	reset &&
	test_git_splice_must_fail four-a..four-c &&
	grep "^fatal: .* is in removal range but not in master" stderr &&
	! test -e four &&
	grep "three b" three &&
	test_splice_not_in_progress
'

test_expect_success 'dirty working tree prevents removing commit on same file' '
	reset &&
	echo dirty >>two &&
	test_when_finished "
		git_splice --abort &&
		test_splice_not_in_progress
	" &&
	test_git_splice_must_fail two-b^! &&
	grep "^error: Your local changes to the following files would be overwritten by checkout:" stderr &&
	grep "^[[:space:]]*two" stderr &&
	grep "^Please commit your changes or stash them before you switch branches" stderr &&
	grep dirty two &&
	test_splice_in_progress
'

test_expect_success 'dirty working tree prevents removing commit on other file' '
	reset &&
	echo dirty >>three &&
	test_when_finished "
		git_splice --abort &&
		test_splice_not_in_progress
	" &&
	test_git_splice_must_fail two-b^! &&
	grep "^error: Your local changes to the following files would be overwritten by checkout:" stderr &&
	grep "^[[:space:]]*three" stderr &&
	grep "^Please commit your changes or stash them before you switch branches" stderr &&
	test_splice_in_progress
'

create_merge_commit () {
	test_when_finished "git tag -d four-merge" &&
	reset &&
	git merge four &&
	git tag four-merge &&
	echo "four d" >>four &&
	git commit -am"four d"
}

test_expect_success 'abort when trying to remove a merge commit' '
	create_merge_commit &&
	test_git_splice_must_fail four-merge^! &&
	grep "^fatal: Removing merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

test_expect_success 'abort when removal range contains merge commits' '
	create_merge_commit &&
	test_git_splice_must_fail four-merge^^..HEAD &&
	grep "^fatal: Removing merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

# The foo.. notation doesn't naturally play nice with our implementation,
# since HEAD gets moved around during the splice.
test_expect_success 'abort when removal range contains merge commits (2)' '
	create_merge_commit &&
	test_git_splice_must_fail four-merge^^.. &&
	grep "^fatal: Removing merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

#############################################################################
# Inserting a single commit

test_expect_success 'insert single commit at HEAD' '
	reset &&
	git_splice HEAD four-a^! &&
	grep "two b" two &&
	grep "three a" three &&
	grep "four a" four &&
	! grep "four b" four &&
	git log --format=format:%s, | xargs |
		grep "four a, three b, three a, two b," &&
	test_splice_not_in_progress
'

test_expect_success 'insert single commit within branch' '
	reset &&
	git_splice two-b four-a^! &&
	grep "two b" two &&
	grep "three a" three &&
	grep "four a" four &&
	! grep "four b" four &&
	git log --format=format:%s, | xargs |
		grep "three b, three a, four a, two b," &&
	test_splice_not_in_progress
'

create_five_branch () {
	test_when_finished "
		git branch -D five &&
		git tag -d five-{a,b,c,merge}
	" &&
	setup_other_branch five one-b a b &&
	git checkout five &&
	git merge four-a &&
	git tag five-merge &&
	echo "five c" >>five &&
	git commit -am"five c" &&
	git tag five-c &&
	git checkout master
}

test_expect_success 'abort when appending a single merge commit on HEAD' '
	reset &&
	create_five_branch &&
	test_git_splice_must_fail HEAD five-merge^! &&
	grep "^fatal: Inserting merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

test_expect_success 'abort when inserting a single merge commit within branch' '
	reset &&
	create_five_branch &&
	test_git_splice_must_fail HEAD~2 five-merge^! &&
	grep "^fatal: Inserting merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

#############################################################################
# Inserting a range of commits

test_expect_success 'insert commit range' '
	reset &&
	git_splice two-b one-b..four-b &&
	grep "two b" two &&
	grep "three a" three &&
	grep "four b" four &&
	git log --format=format:%s, | xargs |
		grep "three b, three a, four b, four a, two b," &&
	test_splice_not_in_progress
'

test_expect_success 'insert commit causing conflict; abort' '
	reset &&
	test_git_splice_must_fail two-b four-b^! &&
	grep "could not apply .* four b" stderr &&
	grep "git cherry-pick failed" stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	git_splice --abort &&
	test_splice_not_in_progress
'

test_expect_success 'insert commit causing conflict; fix; continue' '
	reset &&
	test_git_splice_must_fail two-b four-b^! &&
	grep "could not apply .* four b" stderr &&
	grep "git cherry-pick failed" stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	echo four merged >four &&
	git add four &&
	git_splice --continue &&
	grep "four merged" four &&
	grep "three b" three &&
	test_splice_not_in_progress
'

test_expect_success 'abort when appending range includes a merge commit' '
	reset &&
	create_five_branch &&
	test_git_splice_must_fail HEAD five-a^..five &&
	grep "^fatal: Inserting merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

test_expect_success 'abort when inserting range includes a merge commit' '
	reset &&
	create_five_branch &&
	test_git_splice_must_fail HEAD~2 five-a^..five &&
	grep "^fatal: Inserting merge commits is not supported" stderr &&
	test_splice_not_in_progress
'

#############################################################################
# Removing a range and inserting one or more commits

test_expect_success 'remove range; insert commit' '
	reset &&
	git_splice two-a^..two-b four-a^! &&
	grep "four a" four &&
	! grep "four b" four &&
	grep "three b" three &&
	! test -e two &&
	test_splice_not_in_progress
'

test_expect_success 'remove range; insert commit range' '
	reset &&
	git_splice two-a^..two-b four-a^..four-b &&
	grep "four b" four &&
	! grep "four c" four &&
	grep "three b" three &&
	! test -e two &&
	test_splice_not_in_progress
'

test_expect_success 'remove range; insert commit causing conflict; abort' '
	reset &&
	test_git_splice_must_fail two-a^..two-b four-b^! &&
	grep "could not apply .* four b" stderr &&
	grep "git cherry-pick failed" stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stderr &&
	grep "or run \"git splice --abort\" to abandon the splice" stderr &&
	test_splice_in_progress &&
	git_splice --abort &&
	test_splice_not_in_progress
'

test_remove_range_insert_commit_fix_conflict_continue () {
	reset &&
	test_git_splice_must_fail two-a^..two-b "$@" four-b^! &&
	grep "could not apply .* four b" stderr &&
	grep "git cherry-pick failed" stderr &&
	grep "When you have resolved this problem, run \"git splice --continue\"" stdout stderr &&
	grep "or run \"git splice --abort\"" stdout stderr &&
	test_splice_in_progress &&
	echo four merged >four &&
	git add four &&
	git_splice --continue &&
	grep "four merged" four &&
	grep "three b" three &&
	! test -e two &&
	test_splice_not_in_progress
}

test_expect_success 'remove range; insert commit causing conflict; fix; continue' '
	test_remove_range_insert_commit_fix_conflict_continue
'

test_expect_success 'remove range -- insert commit causing conflict; fix; continue' '
	test_remove_range_insert_commit_fix_conflict_continue --
'

test_expect_success 'remove grepped commits; insert grepped commits' '
	reset &&
	git_splice --grep=two -n1 three-b -- --grep=four --skip=1 four &&
	grep "two a" two &&
	! grep "two b" two &&
	grep "four b" four &&
	! grep "four c" four &&
	grep "three b" three &&
	test_splice_not_in_progress
'

test_done
