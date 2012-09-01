#include "cache.h"
#include "dir.h"

void validate_path(const char *prefix, const char *path)
{
	if (has_symlink_leading_path(path, strlen(path))) {
		int len = prefix ? strlen(prefix) : 0;
		die(_("'%s' is beyond a symbolic link"), path + len);
	}
}

const char **validate_pathspec(const char *prefix, const char **files)
{
	const char **pathspec = get_pathspec(prefix, files);

	if (pathspec) {
		const char **p;
		for (p = pathspec; *p; p++) {
			validate_path(prefix, *p);
		}
	}

	return pathspec;
}

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

void treat_gitlink(const char *path)
{
	int i, len = strlen(path);
	for (i = 0; i < active_nr; i++) {
		struct cache_entry *ce = active_cache[i];
		if (S_ISGITLINK(ce->ce_mode)) {
			int len2 = ce_namelen(ce);
			if (len <= len2 || path[len2] != '/' ||
			    memcmp(ce->name, path, len2))
				continue;
			if (len == len2 + 1)
				/* strip trailing slash */
				path = xstrndup(ce->name, len2);
			else
				die (_("Path '%s' is in submodule '%.*s'"),
				     path, len2, ce->name);
		}
	}
}

void treat_gitlinks(const char **pathspec)
{
	if (!pathspec || !*pathspec)
		return;

	int i;
	for (i = 0; pathspec[i]; i++)
		treat_gitlink(pathspec[i]);
}
