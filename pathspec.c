#include "cache.h"
#include "dir.h"
#include "pathspec.h"

void fill_pathspec_matches(const char **pathspec, char *seen, int specs)
{
	int num_unmatched = 0, i;

	/*
	 * Since we are walking the index as if we were walking the directory,
	 * we have to mark the matched pathspec as seen; otherwise we will
	 * mistakenly think that the user gave a pathspec that did not match
	 * anything.
	 */
	for (i = 0; i < specs; i++)
		if (!seen[i])
			num_unmatched++;
	if (!num_unmatched)
		return;
	for (i = 0; i < active_nr; i++) {
		struct cache_entry *ce = active_cache[i];
		match_pathspec(pathspec, ce->name, ce_namelen(ce), 0, seen);
	}
}

char *find_used_pathspec(const char **pathspec)
{
	char *seen;
	int i;

	for (i = 0; pathspec[i];  i++)
		; /* just counting */
	seen = xcalloc(i, 1);
	fill_pathspec_matches(pathspec, seen, i);
	return seen;
}

/*
 * Check whether path refers to a submodule, or something inside a
 * submodule.  If the former, returns the path with any trailing slash
 * stripped.  If the latter, dies with an error message.
 */
const char *treat_gitlink(const char *path)
{
	int i, path_len = strlen(path);
	for (i = 0; i < active_nr; i++) {
		struct cache_entry *ce = active_cache[i];
		if (S_ISGITLINK(ce->ce_mode)) {
			int ce_len = ce_namelen(ce);
			if (path_len <= ce_len || path[ce_len] != '/' ||
			    memcmp(ce->name, path, ce_len))
				/* path does not refer to this
				 * submodule or anything inside it */
				continue;
			if (path_len == ce_len + 1) {
				/* path refers to submodule;
				 * strip trailing slash */
				return xstrndup(ce->name, ce_len);
			} else {
				die (_("Path '%s' is in submodule '%.*s'"),
				     path, ce_len, ce->name);
			}
		}
	}
	return path;
}

void treat_gitlinks(const char **pathspec)
{
	int i;

	if (!pathspec || !*pathspec)
		return;

	for (i = 0; pathspec[i]; i++)
		pathspec[i] = treat_gitlink(pathspec[i]);
}

/*
 * Dies if the given path refers to a file inside a symlinked
 * directory.
 */
void validate_path(const char *path, const char *prefix)
{
	if (has_symlink_leading_path(path, strlen(path))) {
		int len = prefix ? strlen(prefix) : 0;
		die(_("'%s' is beyond a symbolic link"), path + len);
	}
}

/*
 * Normalizes argv relative to prefix, via get_pathspec(), and then
 * runs validate_path() on each path in the normalized list.
 */
const char **validate_pathspec(const char **argv, const char *prefix)
{
	const char **pathspec = get_pathspec(prefix, argv);

	if (pathspec) {
		const char **p;
		for (p = pathspec; *p; p++) {
			validate_path(*p, prefix);
		}
	}

	return pathspec;
}
