#!/bin/sh

test_description=gitignores

. ./test-lib.sh

init_vars () {
	global_excludes="$HOME/global-excludes"
}

enable_global_excludes () {
	init_vars
	git config core.excludesfile "$global_excludes"
}

ignore_check () {
	paths="$1" expected="$2" global_args="$3"

	if test -z "$expected"; then
	    >"$HOME/expected" # avoid newline
	else
	    echo "$expected" >"$HOME/expected"
	fi &&
	run_check_ignore "$paths" "$global_args"
}

expect () {
	echo "$*" >"$HOME/expected"
}

run_check_ignore () {
	args="$1" global_args="$2"

	init_vars &&
	rm -f "$HOME/stdout" "$HOME/stderr" "$HOME/cmd" &&
	echo `which git` $global_args check-ignore $args >"$HOME/cmd" &&
	pwd >"$HOME/pwd" &&
	git $global_args check-ignore $args >"$HOME/stdout" 2>"$HOME/stderr" &&
	test_cmp "$HOME/expected" "$HOME/stdout" &&
	test_line_count = 0 "$HOME/stderr"
}

test_expect_success 'setup' '
	init_vars
	mkdir -p a/b/ignored-dir a/submodule b &&
	ln -s b a/symlink &&
	(
		cd a/submodule &&
		git init &&
		echo a > a &&
		git add a &&
		git commit -m"commit in submodule"
	) &&
	git add a/submodule &&
	cat <<-EOF >.gitignore &&
		one
	EOF
	cat <<-EOF >a/.gitignore &&
		two*
		*three
	EOF
	cat <<-EOF >a/b/.gitignore &&
		four
		five
		# this comment should affect the line numbers
		six
		ignored-dir/
		# and so should this blank line:

		!on*
		!two
	EOF
	echo "seven" >a/b/ignored-dir/.gitignore &&
	test -n "$HOME" &&
	cat <<-EOF >"$global_excludes"
		globalone
		!globaltwo
		globalthree
	EOF
'

test_expect_success 'empty command line' '
	test_must_fail git check-ignore 2>"$HOME/stderr" &&
	grep -q "error: No path specified" "$HOME/stderr"
'

test_expect_success 'erroneous use of --' '
	test_must_fail git check-ignore -- 2>"$HOME/stderr" &&
	grep -q "error: No path specified" "$HOME/stderr"
'

test_expect_success '--stdin with superfluous arg' '
	test_must_fail git check-ignore --stdin foo 2>"$HOME/stderr" &&
	grep -q "Can'\''t specify files with --stdin" "$HOME/stderr"
'

test_expect_success '--stdin -z with superfluous arg' '
	test_must_fail git check-ignore --stdin -z foo 2>"$HOME/stderr" &&
	grep -q "Can'\''t specify files with --stdin" "$HOME/stderr"
'

test_expect_success '-z without --stdin' '
	test_must_fail git check-ignore -z 2>"$HOME/stderr" &&
	grep -q "error: -z only makes sense with --stdin" "$HOME/stderr"
'

test_expect_success '-z without --stdin and superfluous arg' '
	test_must_fail git check-ignore -z foo 2>"$HOME/stderr" &&
	grep -q "error: -z only makes sense with --stdin" "$HOME/stderr"
'

test_expect_success 'needs work tree' '
	(
		cd .git &&
		test_must_fail git check-ignore foo 2>"$HOME/stderr"
	) &&
	grep -q "fatal: This operation must be run in a work tree" "$HOME/stderr"

'
test_expect_success 'top-level not ignored' '
	ignore_check foo ""
'

test_expect_success 'top-level ignored' '
	ignore_check one "one: excluded one .gitignore 1"
'

test_expect_success 'sub-directory ignore from top' '
	expect "a/one: excluded one .gitignore 1" &&
	run_check_ignore a/one
'

test_expect_success 'sub-directory local ignore' '
	expect "a/3-three: excluded *three a/.gitignore 2" &&
	run_check_ignore "a/3-three a/three-not-this-one"
'

test_expect_success 'sub-directory local ignore inside a' '
	expect "3-three: excluded *three a/.gitignore 2" &&
	(
		cd a &&
		run_check_ignore "3-three three-not-this-one"
	)
'

test_expect_success 'nested include' '
	expect "a/b/one: included !on* a/b/.gitignore 8" &&
	run_check_ignore "a/b/one"
'

test_expect_success 'ignored sub-directory' '
	expect "a/b/ignored-dir: excluded ignored-dir/ a/b/.gitignore 5" &&
	run_check_ignore "a/b/ignored-dir"
'

test_expect_success 'multiple files inside ignored sub-directory' '
	cat <<-EOF >"$HOME/expected" &&
		a/b/ignored-dir/foo: excluded ignored-dir/ a/b/.gitignore 5
		a/b/ignored-dir/twoooo: excluded ignored-dir/ a/b/.gitignore 5
		a/b/ignored-dir/seven: excluded ignored-dir/ a/b/.gitignore 5
	EOF
	run_check_ignore "a/b/ignored-dir/foo a/b/ignored-dir/twoooo a/b/ignored-dir/seven"
'

test_expect_success 'cd to ignored sub-directory' '
	cat <<-EOF >"$HOME/expected" &&
		foo: excluded ignored-dir/ a/b/.gitignore 5
		twoooo: excluded ignored-dir/ a/b/.gitignore 5
		../one: included !on* a/b/.gitignore 8
		seven: excluded ignored-dir/ a/b/.gitignore 5
		../../one: excluded one .gitignore 1
	EOF
	(
		cd a/b/ignored-dir &&
		run_check_ignore "foo twoooo ../one seven ../../one"
	)
'

test_expect_success 'symlink' '
	ignore_check "a/symlink" ""
'

test_expect_success 'beyond a symlink' '
	test_must_fail git check-ignore "a/symlink/foo"
'

test_expect_success 'beyond a symlink from subdirectory' '
	(
		cd a &&
		test_must_fail git check-ignore "symlink/foo"
	)
'

test_expect_success 'submodule' '
	test_must_fail git check-ignore "a/submodule/one" 2>"$HOME/stderr" &&
	expect "fatal: Path '\''a/submodule/one'\'' is in submodule '\''a/submodule'\''" &&
	test_cmp "$HOME/expected" "$HOME/stderr"
'

test_expect_success 'submodule from subdirectory' '
	(
		cd a &&
		test_must_fail git check-ignore "submodule/one" 2>"$HOME/stderr"
	) &&
	expect "fatal: Path '\''a/submodule/one'\'' is in submodule '\''a/submodule'\''" &&
	test_cmp "$HOME/expected" "$HOME/stderr"
'

test_expect_success 'global ignore not yet enabled' '
	expect "a/globalthree: excluded *three a/.gitignore 2" &&
	run_check_ignore "globalone a/globalthree a/globaltwo"
'

test_expect_success 'global ignore' '
	enable_global_excludes &&
	cat <<-EOF >"$HOME/expected" &&
		globalone: excluded globalone $global_excludes 1
		globalthree: excluded globalthree $global_excludes 3
		a/globalthree: excluded *three a/.gitignore 2
		globaltwo: included !globaltwo $global_excludes 2
	EOF
	run_check_ignore "globalone globalthree a/globalthree globaltwo"
'

test_expect_success '--stdin' '
	cat <<-EOF >in.txt &&
		one
		a/one
		a/b/on
		a/b/one
		a/b/two
		a/b/twooo
		globaltwo
		a/globaltwo
		a/b/globaltwo
		b/globaltwo
	EOF
	cat <<-EOF >"$HOME/expected" &&
		one: excluded one .gitignore 1
		a/one: excluded one .gitignore 1
		a/b/on: included !on* a/b/.gitignore 8
		a/b/one: included !on* a/b/.gitignore 8
		a/b/two: included !two a/b/.gitignore 9
		a/b/twooo: excluded two* a/.gitignore 1
		globaltwo: included !globaltwo $global_excludes 2
		a/globaltwo: included !globaltwo $global_excludes 2
		a/b/globaltwo: included !globaltwo $global_excludes 2
		b/globaltwo: included !globaltwo $global_excludes 2
	EOF
	run_check_ignore --stdin < in.txt
'

test_expect_success '--stdin -z' '
	tr "\n" "\0" < in.txt | run_check_ignore "--stdin -z"
'

test_expect_success '-z --stdin' '
	tr "\n" "\0" < in.txt | run_check_ignore "-z --stdin"
'

test_expect_success '--stdin from subdirectory' '
	cat <<-EOF >in.txt &&
		../one
		one
		b/on
		b/one
		b/two
		b/twooo
		../globaltwo
		globaltwo
		b/globaltwo
		../b/globaltwo
	EOF
	cat <<-EOF >"$HOME/expected" &&
		../one: excluded one .gitignore 1
		one: excluded one .gitignore 1
		b/on: included !on* a/b/.gitignore 8
		b/one: included !on* a/b/.gitignore 8
		b/two: included !two a/b/.gitignore 9
		b/twooo: excluded two* a/.gitignore 1
		../globaltwo: included !globaltwo $global_excludes 2
		globaltwo: included !globaltwo $global_excludes 2
		b/globaltwo: included !globaltwo $global_excludes 2
		../b/globaltwo: included !globaltwo $global_excludes 2
	EOF
	(
		cd a &&
		run_check_ignore --stdin < ../in.txt
	)
'

test_expect_success '--stdin -z from subdirectory' '
	tr "\n" "\0" < in.txt | ( cd a && run_check_ignore "--stdin -z" )
'

test_expect_success '-z --stdin from subdirectory' '
	tr "\n" "\0" < in.txt | ( cd a && run_check_ignore "-z --stdin" )
'


test_done
