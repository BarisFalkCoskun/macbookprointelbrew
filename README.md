# Intel bottles for macOS 15

Homebrew 7 stopped building bottles for Intel Macs, so on an Intel MacBook
every formula update compiles from source. This repo builds those bottles
on GitHub's Intel macOS 15 runners (`macos-15-intel`, free for public repos)
and publishes them as assets on the `bottles` release. `ibrew` on the MacBook
downloads and pours them instead of compiling.

- **Nightly**: `build-bottles.yml` rebuilds whatever in `packages.txt` (plus
  dependencies) has no official or published bottle for Homebrew's current version.
- **On demand**: `ibrew install foo` asks the workflow for missing bottles,
  waits, then pours them.
- Formulae that still have an official Intel bottle, casks, and third-party
  taps are left to plain `brew`.

## Setup

1. Create an empty **public** GitHub repo (e.g. `intel-bottles`) and push this
   folder to its `main` branch. The first push starts a full build of
   `packages.txt`. It takes many hours (llvm, rust, qt, ...) and continues
   itself across runs; progress is on the repo's Actions tab.
2. Create a fine-grained token: Settings → Developer settings → Fine-grained
   tokens. Repository access: only this repo. Permissions: **Actions: Read and
   write**. That's all it needs (downloads are public).
3. On the MacBook:

   ```sh
   git clone https://github.com/<you>/intel-bottles && cd intel-bottles
   client/setup.sh <you>/intel-bottles   # asks for the token, stores it in the Keychain
   ```

## Usage

```sh
ibrew upgrade                 # all outdated formulae (bottles from here) + casks
ibrew install wget --dry-run  # show where each formula would come from
ibrew install wget
ibrew reinstall opencv
```

Any other command or flag goes straight to `brew`. Bottles are cached in
`~/Library/Caches/ibrew`. Tuning (env vars): `HOMEBREW_IBREW_WAIT_MINUTES`
(default 240) is how long `ibrew` waits for a remote build.

To keep a new formula prebuilt every night, add it to `packages.txt` and push.

## Limits

- `macos-15-intel` runners end in August 2027, and Homebrew drops Intel
  entirely on 1 September 2027. After that, MacPorts still supports Intel Macs.
- A single build that takes more than ~5.5 h is stopped and recorded as failed
  in `index.json`. Nightly runs won't retry it at the same version, but
  requesting it by name (`ibrew install`, or *Run workflow* with its name) will.
