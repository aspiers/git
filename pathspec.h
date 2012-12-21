extern char *find_used_pathspec(const char **pathspec);
extern void fill_pathspec_matches(const char **pathspec, char *seen, int specs);
extern const char *treat_gitlink(const char *path);
extern void treat_gitlinks(const char **pathspec);
extern const char **validate_pathspec(const char **argv, const char *prefix);
