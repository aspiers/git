#!/bin/sh
#
# Copyright (c) 2010 Jon Seymour
#

test_description='git-test tests

Checks that the git-test conditions are correctly evaluated.
'

. ./test-lib.sh
. $(git --exec-path)/git-test-lib.sh

cat >test-assertions-lib.sh <<EOF
check_always_fails_0_0()
{
	echo "always-fails-0"
	false
}

check_always_fails_1_1()
{
	echo "always-fails-1 \$1"
	false
}

check_never_fails_0_0()
{
	echo "never-fails-0"
	true
}

check_never_fails_1_1()
{
	echo "never-fails-1 \$1"
	true
}
EOF
cat >empty-assertions-lib.sh <<EOF
EOF

git config condition.lib "$(pwd)/test-assertions-lib.sh"
git config --add condition.lib "$(pwd)/empty-assertions-lib.sh"

test_expect_assertion_failure()
{
	test=$1
	message=$2
	shift 
	test_expect_success $1 \
"
	! actual_message=$(git test "$@" 1>&2) &&
	test "$message" = "$actual_message"
"
}

#        G
#       /
# base-A---M--C--D--D1--E
#     \   / \
#      -B-   -F

test_expect_success 'setup' \
'
	git add test-assertions-lib.sh empty-assertions-lib.sh && 
	test_commit base &&
	test_commit A &&
	git checkout A^1 &&
	test_commit B && 
	git checkout master &&
	test_merge M B &&
	echo C >> B.t &&
	git tag STASH_UNSTAGED $(git stash create) &&
	git add B.t &&
	git tag STASH_STAGED $(git stash create) &&
	test_commit C &&
	test_commit D &&
	git commit -m "allow-empty" --allow-empty &&
	git tag D1 &&
	test_commit E &&
	git checkout M^0 -- &&
        echo F >> B.t &&
        git add B.t &&
	test_commit F &&
	git checkout A^0 -- &&
	test_commit G &&
	git checkout master &&
	git reset --hard D     
'

test_expect_success 'git test # no arguments' \
'
	git test &&
	test -z "$(git test)"
'

test_expect_success 'git test -q # -q only' \
'
	git test -q &&
	test -z "$(git test)"
'

test_expect_success 'git test --message msg # with a message' \
'
	git test --message msg &&
	test -z "$(git test)"
'

test_expect_success 'git test --message "" # with an empty message' \
'
	git test --message "" &&
	test -z "$(git test)"
'

test_expect_success 'git test --message # should fail' \
'
	test_must_fail git test --message
'

test_expect_success 'git test --invalid-condition # should fail' \
'
	test_must_fail git test --invalid-condition
'

test_expect_success 'git test --not-invalid-condition # should fail' \
'
	test_must_fail git test --not-invalid-condition
'

test_expect_success 'git test --invalid-condition --never-fails-0 # should fail' \
'
	test_must_fail git test --invalid-condition --never-fails-0
'

test_expect_success 'git test --invalid-condition one-arg --never-fails-0 #should fail' \
'
	test_must_fail git test --invalid-condition one-arg --never-fails-0
'

test_expect_success 'git test --never-fails-0' \
'
	git test --never-fails-0
'

test_expect_success 'git test --never-fails-1 # missing argument - should fail' \
'
	test_must_fail git test --never-fails-1
'

test_expect_success 'git test --never-fails-1 one-arg' \
'
	git test --never-fails-1 one-arg
'

test_expect_success 'git test --not-never-fails-0 # should fail' \
'
	test_must_fail git test --not-never-fails-0
'

test_expect_success 'git test --always-fails-0 # should fail' \
'
	test_must_fail git test --always-fails-0
'

test_expect_success 'git test --always-fails-1 # should fail' \
'
	test_must_fail git test --always-fails-1 one-arg
'

test_expect_success 'git test --not-always-fails-1 one-arg' \
'
	git test --not-always-fails-1 one-arg
'

test_expect_success 'git test --not-always-fails-1 # should fail' \
'
	test_must_fail git test --not-always-fails-1
'

test_expect_success 'git test --not-always-fails-0' \
'
	git test --not-always-fails-0
'

test_expect_success 'git test --unstaged # should fail' \
'
	test_must_fail git test --unstaged
'

test_expect_success 'git test --not-unstaged' \
'
	git test --not-unstaged
'

test_expect_success 'git test --unstaged # when there are unstaged files' \
'
	test_when_finished "git reset --hard HEAD && git checkout master" && 
	git checkout -f M^0 &&
	git stash apply --index STASH_UNSTAGED &&
	git test --unstaged
'

test_expect_success 'git test --not-unstaged # when there are unstaged files - should fail' \
'
	test_when_finished "git reset --hard HEAD && git checkout master" && 
	git checkout -f M^0 &&
	git stash apply --index STASH_UNSTAGED &&
	test_must_fail git test --not-unstaged
'

test_expect_success 'git test --unstaged # when there are only staged files' \
'
	test_when_finished "git reset --hard HEAD && git checkout master" && 
	git checkout -f M^0 &&
	git stash apply --index STASH_STAGED &&
	git test --not-unstaged
'

test_expect_success 'git test --staged # should fail' \
'
	test_must_fail git test --staged
'

test_expect_success 'git test --not-staged' \
'
	git test --not-staged
'

test_expect_success 'git test --staged # when there are staged files' \
'
	test_when_finished "git reset --hard HEAD && git checkout master" && 
	git checkout -f M^0 &&
	git stash apply --index STASH_STAGED &&
	git test --staged
'

test_expect_success 'git test --not-staged # when there are staged files - should fail' \
'
	test_when_finished "git reset --hard HEAD && git checkout master" && 
	git checkout -f M^0 &&
	git stash apply --index STASH_STAGED &&
	test_must_fail git test --not-staged
'

test_expect_success 'git test --staged # when there are only unstaged files' \
'
	test_when_finished "git reset --hard HEAD && git checkout master" && 
	git checkout -f M^0 &&
	git stash apply --index STASH_UNSTAGED &&
	git test --not-staged
'

test_expect_success 'git test --untracked # should fail' \
'
	test_must_fail git test --untracked
'

test_expect_success 'git test --not-untracked' \
'
	git test --not-untracked
'

test_expect_success 'git test --untracked # when there are untracked files' \
'
	test_when_finished "git clean -fd" && 
	:> untracked &&
	git test --untracked
'

test_expect_success 'git test --not-untracked # when there are untracked files - should fail' \
'
	test_when_finished "git clean -fd" && 
	:> untracked &&
	test_must_fail git test --not-untracked
'

test_expect_success 'git test --not-detached' \
'
	git test --not-detached
'

test_expect_success 'git test --detached # should fail' \
'
	test_must_fail git test --detached
'

test_expect_success 'git test --not-detached # when detached, should fail' \
'
	test_when_finished "git checkout -f master" && 
	git checkout HEAD^0 &&
	test_must_fail git test --not-detached
'

test_expect_success 'git test --detached # when detached' \
'
	test_when_finished "git checkout -f master" && 
	git checkout HEAD^0 &&
	git test --detached
'

test_done
