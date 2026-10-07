# pds-test

Container images of atproto PDS implementations and the PLC directory, built
nightly for testing.

| Target | Source | Tracks | Gated |
|---|---|---|---|
| `plc` | did-method-plc | `main` | no |
| `tranquil` | tranquil-pds, with `native-tls-roots` | highest `vX.Y.Z` tag | no |
| `cocoon` | haileyok/cocoon | `main` | no |
| `zds` | zat.dev/zds | `main` | yes |
| `pdsjs` | chadtmiller.com/pds.js | `main` | yes |
| `atproto-pds` | ngerakines.me/atproto-crates | `main` | yes |
| `vlpds` | jazware/vlpds | `main` | yes |
| `pds-spaces-alpha` | Bluesky's `pds-spaces-alpha` image | its tag | yes |

Images are published to `ghcr.io/happyproto/pds-test/<target>` for amd64 and
arm64. `pds-spaces-alpha` is amd64 only, because Bluesky publishes only amd64.
Each image has three tags:

- `fp-<fingerprint>`: identifies one set of inputs and never moves
- `upstream-<commit>`: the upstream commit the image was built from
- `latest`: the newest image

## When a target is rebuilt

A target is rebuilt when its fingerprint changes. The fingerprint is a hash of
the target's build settings and of the paths listed in its `inputs`, so upstream
commits that touch other paths do not cause a rebuild. The header of
[`scripts/fingerprint.sh`](scripts/fingerprint.sh) describes how it is computed,
including for Rust workspaces.

To compare two commits, fingerprint each one:

```sh
FINGERPRINT_REPO=file:///path/to/clone FINGERPRINT_REV=<commit> scripts/fingerprint.sh <target>
```

Fetching from a local clone requires `uploadpack.allowFilter` and
`uploadpack.allowAnySHA1InWant` to be set in that clone.

## Consumers

When a gated target gets a new image, every repository in `consumers` receives a
`repository_dispatch` event:

```json
{
  "event_type": "pds-test-image",
  "client_payload": {
    "target": "zds",
    "image": "ghcr.io/happyproto/pds-test/zds@sha256:…",
    "fingerprint": "4e5f5b496c125316",
    "upstream": "<commit>",
    "ref": "main",
    "run": "<URL of the workflow run that built the image>"
  }
}
```

Consumers decide whether to test, pin or reject the image. Ungated targets send
no event; consumers use `latest`.

## Adding a target

1. Add an entry to `targets.json`. The `_comment` at the top describes each
   field. Under `inputs`, list every path that affects the image, based on the
   Dockerfile's `COPY` lines and the build. A missing path means changes to it
   are not built; an extra path only causes an extra build. Include a path when
   unsure.
2. Run `scripts/fingerprint.sh <target>`. Check that a docs-only commit keeps
   the fingerprint of its parent and a source commit changes it.
3. Run **Actions → Nightly images → Run workflow** with `targets` set to the new
   target.

If the upstream image is missing something consumers need, add a Dockerfile to
`dockerfiles/` and set `local_dockerfile` instead of `dockerfile`.

## Setup

- `npm ci` installs the TOML parser `scripts/cargo-closure.mjs` uses.
- **`CONSUMER_DISPATCH_TOKEN`** (secret): a token that can send
  `repository_dispatch` events to each repository in `consumers`. A classic
  token needs the `public_repo` scope for public consumers or `repo` for private
  ones. A fine-grained token needs **Contents: Read and write** on each. The
  token's owner needs write access to every consumer. Without this secret, the
  notify job fails.
- **Package visibility**: GitHub creates each package as private. Make each
  `pds-test/<target>` package public after its first publish, so repositories in
  other organizations can pull it.
- **`RUNNER_AMD64`, `RUNNER_ARM64`** (variables, optional): runner labels.
  Defaults are `ubuntu-24.04` and `ubuntu-24.04-arm`.
