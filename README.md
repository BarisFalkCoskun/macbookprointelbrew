# Intel bottles for macOS 15

Homebrew 7 no longer ships prebuilt packages (bottles) for Intel Macs, so
`brew` compiles everything. This repo builds them on GitHub's Intel runners
instead, and `ibrew` on the MacBook installs them.

## Cheat sheet

| Instead of | Type | What happens |
|---|---|---|
| `brew install foo` | `ibrew install foo` | Installs a prebuilt bottle; if there's none yet, GitHub builds it and `ibrew` waits |
| `brew upgrade` | `ibrew upgrade` | Same, for everything outdated (apps go to plain `brew`) |
| `brew upgrade foo` | `ibrew upgrade foo` | Same, for one formula |
| `brew reinstall foo` | `ibrew reinstall foo` | Same, even if it's up to date |
| anything else | `brew …` or `ibrew …` | Identical (`ibrew` passes it to `brew`) |

- **Preview:** add `--dry-run` to see the plan without changing anything.
- **Don't use** plain `brew install`, `upgrade` or `reinstall`: they compile.
  To keep typing `brew`: `echo 'alias brew=ibrew' >> ~/.zshrc`
- **Other flags** (except `--cask`) send the command to plain `brew`, which may compile.
- **First request can be slow:** big formulae (llvm, rust) take hours on
  GitHub. Ctrl-C is safe; run the command again later.

## How it works

- **Nightly:** GitHub builds anything in `packages.txt` (plus dependencies)
  that has a newer version than its bottle. Add a formula there and push to
  keep it prebuilt.
- **On demand:** `ibrew` checks what's outdated on the MacBook and asks GitHub
  to build only what's missing.
- Bottles and `index.json` (the list of them) live on the `bottles` release.

## Setup

1. Push this repo to a **public** GitHub repo.
2. Create a fine-grained token (Settings → Developer settings), for this repo
   only, with **Actions: Read and write**.
3. On the MacBook (the argument is the GitHub `owner/repo`, not your Mac username):

   ```sh
   git clone https://github.com/BarisFalkCoskun/macbookprointelbrew && cd macbookprointelbrew
   client/setup.sh BarisFalkCoskun/macbookprointelbrew   # stores the token in the Keychain
   ```

**Updating `ibrew`:** `git pull`, then run `client/setup.sh …` again (it won't ask for the token).

## Rebuild by hand

```sh
gh workflow run build-bottles.yml -R BarisFalkCoskun/macbookprointelbrew               # nightly-style
gh workflow run build-bottles.yml -R BarisFalkCoskun/macbookprointelbrew -f formulae="llvm rust"
```

Naming formulae also retries ones that failed before; the nightly-style run doesn't.

## Limits

- GitHub's Intel runners end in August 2027; Homebrew drops Intel on
  1 September 2027. After that, use MacPorts.
- A build that takes more than ~5.5 h is stopped and marked as failed.
