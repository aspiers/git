#include "builtin.h"
#include "cache.h"
#include "dir.h"
#include "quote.h"
#include "pathspec.h"
#include "parse-options.h"

static int stdin_paths;
static const char * const check_ignore_usage[] = {
"git check-ignore pathname...",
"git check-ignore --stdin [-z] < <list-of-paths>",
NULL
};

static int null_term_line;

static const struct option check_ignore_options[] = {
	OPT_BOOLEAN(0 , "stdin", &stdin_paths, "read file names from stdin"),
	OPT_BOOLEAN('z', NULL, &null_term_line,
		"input paths are terminated by a null character"),
	OPT_END()
};

static void output_exclude(const char *path, struct exclude *exclude)
{
	char *type = exclude->to_exclude ? "excluded" : "included";
	char *bang = exclude->to_exclude ? "" : "!";
	char *dir  = (exclude->flags & EXC_FLAG_MUSTBEDIR) ? "/" : "";
	printf(_("%s: %s %s%s%s "), path, type, bang, exclude->pattern, dir);
	if (exclude->srcpos > 0) {
		printf("%s %d", exclude->src, exclude->srcpos);
	}
	else {
		/* Exclude was from CLI parameter.  This code path is
		 * currently impossible to hit, but later on we might
		 * want to add ignore tracing to other commands such
		 * as git clean, which does accept --exclude.
		 */
		/* printf("%s %d", exclude->src, -exclude->srcpos); */
	}
	printf("\n");
}

static void check_ignore(const char *prefix, const char **pathspec)
{
	struct dir_struct dir;
	const char *path;
	char *seen = NULL;

	/* read_cache() is only necessary so we can watch out for submodules. */
	if (read_cache() < 0)
		die(_("index file corrupt"));

	memset(&dir, 0, sizeof(dir));
	dir.flags |= DIR_COLLECT_IGNORED;
	setup_standard_excludes(&dir);

	if (pathspec) {
		int i;
		struct path_exclude_check check;
		struct exclude *exclude;

		path_exclude_check_init(&check, &dir);
		if (!seen)
			seen = find_used_pathspec(pathspec);
		for (i = 0; pathspec[i]; i++) {
			path = pathspec[i];
			char *full_path =
				prefix_path(prefix, prefix ? strlen(prefix) : 0, path);
			treat_gitlink(full_path);
			validate_path(prefix, full_path);
			if (!seen[i] && path[0]) {
				int dtype = DT_UNKNOWN;
				exclude = path_excluded_1(&check, full_path, -1, &dtype);
				if (exclude) {
					output_exclude(path, exclude);
				}
			}
		}
		free(seen);
		free_directory(&dir);
		path_exclude_check_clear(&check);
	}
	else {
		printf("no pathspec\n");
	}
}

static void check_ignore_stdin_paths(const char *prefix)
{
	struct strbuf buf, nbuf;
	char **pathspec = NULL;
	size_t nr = 0, alloc = 0;
	int line_termination = null_term_line ? 0 : '\n';

	strbuf_init(&buf, 0);
	strbuf_init(&nbuf, 0);
	while (strbuf_getline(&buf, stdin, line_termination) != EOF) {
		if (line_termination && buf.buf[0] == '"') {
			strbuf_reset(&nbuf);
			if (unquote_c_style(&nbuf, buf.buf, NULL))
				die("line is badly quoted");
			strbuf_swap(&buf, &nbuf);
		}
		ALLOC_GROW(pathspec, nr + 1, alloc);
		pathspec[nr] = xcalloc(strlen(buf.buf) + 1, sizeof(*buf.buf));
		strcpy(pathspec[nr++], buf.buf);
	}
	ALLOC_GROW(pathspec, nr + 1, alloc);
	pathspec[nr] = NULL;
	check_ignore(prefix, (const char **)pathspec);
	maybe_flush_or_die(stdout, "attribute to stdout");
	strbuf_release(&buf);
	strbuf_release(&nbuf);
	free(pathspec);
}

static NORETURN void error_with_usage(const char *msg)
{
	error("%s", msg);
	usage_with_options(check_ignore_usage, check_ignore_options);
}

int cmd_check_ignore(int argc, const char **argv, const char *prefix)
{
	git_config(git_default_config, NULL);

	argc = parse_options(argc, argv, prefix, check_ignore_options,
			     check_ignore_usage, 0);

	if (stdin_paths) {
		if (0 < argc)
			error_with_usage("Can't specify files with --stdin");
	} else {
		if (null_term_line)
			error_with_usage("-z only makes sense with --stdin");

		if (argc == 0)
			error_with_usage("No path specified");
	}

	if (stdin_paths)
		check_ignore_stdin_paths(prefix);
	else {
		check_ignore(prefix, argv);
		maybe_flush_or_die(stdout, "ignore to stdout");
	}

	return 0;
}
