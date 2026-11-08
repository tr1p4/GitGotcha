# gg.sh

Find the email addresses a GitHub user has committed with.

`gg.sh` queries the GitHub commits search API for a username, collects the author
email from every matching commit, and prints a unique, sorted list to stdout.
Requires nothing but a POSIX system with `curl`, `jq` and `sort`; the bundled copy
of [modernish](https://github.com/modernish/modernish#readme) (in `bndl/`) means
no shell library install is needed.

## Usage

```sh
./gg.sh -u <username>
```

```
Usage: ./gg.sh -u <username> [-t <token>] [-n]
       GITHUB_TOKEN=<token> ./gg.sh -u <username> [-n]

Options:
  -u <username>   GitHub username to search commits for (required)
  -t <token>      GitHub token (exposes it via ps(1); prefer GITHUB_TOKEN)
  -n              Include @users.noreply.github.com proxy addresses
```

The token is taken from `-t`, then `$GITHUB_TOKEN`, then an interactive prompt.
A token is required: the commits search endpoint is not usable anonymously.

### Example

```sh
GITHUB_TOKEN=ghp_xxx ./gg.sh -u octocat
```

Emails go to stdout (one per line); progress and errors go to stderr, so the list
is safe to pipe. `@users.noreply.github.com` addresses are skipped by default
because they are GitHub proxies rather than real mailboxes — pass `-n` to keep them.

## Notes

- Results are capped by GitHub's search API at 1000 commits (the script stops and
  says so when it hits the limit).
- Exit status is 0 on success and 1 when no addresses were found; a warning is
  printed for an invalid user or a token missing the `repo` scope.
- `gg.sh` at the repository root is a small wrapper that locates `bndl/` and runs
  the real script under the bundled modernish. Keep the directory layout together.

## Licence

The bundled modernish 0.17.23-dev is Free software by Martijn Dekker; see
`bndl/README.modernish` for its licence. That licence covers modernish only, not
this script.
