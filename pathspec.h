extern void validate_path(const char *prefix, const char *path);
extern const char **validate_pathspec(const char *prefix, const char **files);
extern char *find_used_pathspec(const char **pathspec);
extern void fill_pathspec_matches(const char **pathspec, char *seen, int specs);
extern void treat_gitlink(const char *path);
extern void treat_gitlinks(const char **pathspec);
