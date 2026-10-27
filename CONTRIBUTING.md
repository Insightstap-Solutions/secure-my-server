# Contributing

Thank you for helping. The most valuable contributions are **guides and detector support for server setups this plugin does not know yet**, and **traps**: real mistakes, with what happened and the rule that prevents them.

## Ground rules
1. **Nothing that could identify a real server or company.** No real hostnames, IPs (use `203.0.113.x`), emails, customer names or secrets, in code, docs, tests or commit messages. `tools/check_repo.py` catches some of this; you are responsible for the rest.
2. **Detectors stay read-only** and never print secret values or file contents. One finding per line: `LEVEL<TAB>CHECK<TAB>DETAIL`, with LEVEL one of `CRIT WARN INFO OK SKIP`.
3. **Scripts are single, self-contained files.** They are piped over ssh (`ssh host 'bash -s' < script.sh`), so they cannot `source` anything. They must work on bash 4.2+, guard every optional tool with `command -v`, and pass `shellcheck`.
4. **Facts need a source.** A guide that names a path, a package or a command should be right for that stack; link the official docs under "Sources", and mark anything you could not confirm with "(verify on your system)".
5. **Simple English.** Short sentences, common words. Many users read English as a second language.

## Before you open a pull request
```bash
tests/run.sh                       # shellcheck + bats
python3 tools/check_repo.py        # frontmatter, paths, version, privacy
claude plugin validate . --strict  # if you have Claude Code
```
If you change behaviour, add a line to `CHANGELOG.md`. A release also bumps `version` in `plugins/secure-my-server/.claude-plugin/plugin.json`, then `claude plugin tag plugins/secure-my-server --push`.

## Adding a new stack
1. A fixture under `tests/fixtures/` that looks like that server (fake files and tiny shim binaries; never real PHP).
2. Detection in `plugins/secure-my-server/scripts/detect_stack.sh` and/or `php_runtimes.sh`, with a test.
3. A guide in `plugins/secure-my-server/guides/`, with the same sections as the others, and a row in its `README.md`.

**Keep test data out of the plugin folder.** Only `plugins/secure-my-server/` is installed and published; fixtures that look like web shells or keys belong in `tests/`.
