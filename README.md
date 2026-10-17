# Adversary Actions

Reusable GitHub Actions for publishing adversaries and submitting hosted Doomer reviews.

| Action | Status | Purpose |
| --- | --- | --- |
| [`version`](version) | Available | Synchronize release metadata and runtime identity, rebuild, verify, and commit from a release version. |
| [`push`](push) | Available | Validate, build, package, and push an adversary to an OCI registry. |
| [`review`](review) | Available | Submit the checked-out Git worktree for a hosted review using Doomer CLI 2026.10.17. |

## Version an adversary

The version action treats a `v`-prefixed release version as the source of truth. It updates `adversary.yaml`, synchronizes npm package metadata when present, safely updates a single literal `version` property in the `new Adversary({...})` initializer, rebuilds Node projects, and imports the built runtime to require `createApp().version` to equal the release version. Changed, already tracked `dist/` artifacts are included in the metadata commit. Reruns verify and reuse an existing version commit instead of creating another one.

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
  with:
    fetch-depth: 0
    persist-credentials: false

- uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
  with:
    node-version: 22

- name: Synchronize release metadata
  id: version
  uses: doomerlabs/actions/version@v1
  with:
    tag: ${{ github.ref_name }}
    token: ${{ secrets.RELEASE_GITHUB_TOKEN }}

- name: Push
  uses: doomerlabs/actions/push@v1
  with:
    auth-mode: token
    token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
    registry-namespace: your-team-slug
    repository-name: ${{ steps.version.outputs.name }}
    push-latest: true
```

Use a fine-grained GitHub token limited to repository contents read/write. The action stores Git authentication only for its fetch and push operations, removes it before returning, never force-pushes, and never receives the registry credential. `sync-npm: auto` updates `package.json` and `package-lock.json` when `package.json` exists; set it to `false` for non-npm adversaries or `true` to require npm metadata.

For Node adversaries, the runtime command must identify a project-relative JavaScript entrypoint and the built module must export `createApp()`. A literal runtime version is synchronized with a token-aware source edit; computed or omitted versions are left untouched and accepted only when the rebuilt app reports the correct version (for example, when a future SDK infers it from package metadata). Multiple initializers and runtimes that cannot prove their identity fail closed. Non-Node adversaries keep the metadata-only behavior. Dependency installation and builds use the repository's npm, pnpm, or Yarn lockfile; an existing build script is run when present.

### Prepare before tagging

Existing tag-triggered workflows remain supported, but they necessarily build from a working tree that differs from the tag when a version update is needed. For signed tag/runtime identity, run this action on the release branch *before* creating the tag: pass the intended `v<version>` as `tag`, wait for the action to push its commit, then create the annotated or signed tag at `${{ steps.version.outputs.commit }}`. The existing release workflow should become verify-and-publish-only for that tag. This ordering makes the tagged tree, rebuilt runtime, registry bytes, and protocol version identical.

The preparation workflow should check out the release branch itself (not a tag) with full history, invoke `version` with the intended tag text, and hand its `commit` output to authorized signing/release tooling. That tooling must fetch the pushed commit and create the tag at that exact object; it should reject an existing tag or a branch that advanced unexpectedly. The tag-triggered workflow then validates and publishes without mutating source.

During migration, do not create the tag until the version step succeeds. The backward-compatible tag-triggered mode still fixes and verifies the published runtime and main-branch metadata, but it cannot retroactively change the already-created tag object.

### Version inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `tag` | yes | — | Intended release tag formatted as `v<semantic-version>`; it may be prepared before the tag exists. |
| `path` | no | `.` | Adversary project directory. |
| `branch` | no | `main` | Branch that receives the version commit. |
| `token` | yes | — | Fine-grained GitHub token with repository contents read/write. |
| `sync-npm` | no | `auto` | Synchronize npm metadata when present (`auto`, `true`, or `false`). |

### Version outputs

| Output | Description |
| --- | --- |
| `name` | OCI-compatible name from `adversary.yaml`. |
| `version` | Semantic version without the tag's `v` prefix. |
| `changed` | Whether this invocation created and pushed a version commit. |
| `commit` | Version bump commit, or current branch commit when unchanged. |

## Push an adversary

The push action uses the current `doomer adversary pack` and `doomer adversary push` commands. It installs a Doomer CLI release from `doomerlabs/doomer`, verifies the release archive against `checksums.txt`, validates the project, packages it, and pushes both the OCI image manifest and adversary-manifest referrer. Private publishes to the authenticated team namespace on the Doomer registry are signed automatically; the publisher receives only the signature and public team delegation, never a private key.

```yaml
name: Push adversary

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read
  id-token: write

jobs:
  push:
    runs-on: depot-ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
        with:
          node-version: 22
          cache: npm

      - name: Push
        id: push
        uses: doomerlabs/actions/push@v1
        with:
          path: .
          registry-namespace: your-team-slug
          repository-name: security-reviewer
          push-latest: true

      - name: Report digest
        run: echo "Pushed ${{ steps.push.outputs.reference }} at ${{ steps.push.outputs.digest }}"
```

When `cli-version` is omitted, the push action installs its pinned default, `2026.10.17`. Set `cli-version` explicitly to test a different release. Pin the action itself to an exact release tag or full commit SHA for reproducible CI.

The local builder installs dependencies from `package-lock.json`, `pnpm-lock.yaml`, or `yarn.lock`; configure the matching Node runtime before invoking the action. pnpm and Yarn installs require Corepack, which is not bundled with Node.js 25 and later; install Corepack separately on those runtimes. For reproducible pnpm or Yarn installs, pin the exact tool version in the `packageManager` field of `package.json`.

### Authentication

The default `auth-mode: auto` requests the job identity with audience `https://doomer.ai`, exchanges it for a ten-minute team credential, and deletes the temporary CLI profile afterward. Add `permissions: id-token: write`, trust the repository under the team page, and pass the team slug as `registry-namespace`. This works both in GitHub Actions and native Depot CI workflows; Depot identities can also be pinned to the Depot organization ID. For v1 compatibility, `auto` selects token authentication when the `token` input is populated; explicit `oidc` never falls back to a long-lived token.

For CI systems without compatible OIDC, `auth-mode: token` accepts an Doomer service-account token. Create one with `registry:push`, store it as a CI secret, and pass it through the `token` input.

For an interactive run, set `auth-mode: oauth`. The CLI prints a device-login URL and code and waits for approval through your normal OAuth login. The device request currently expires after ten minutes.

Set `auth-mode: existing` to skip login. This supports a runner with a preconfigured CLI profile or an external OCI registry authenticated through Docker’s credential store. When `profile` is omitted, the action uses the CLI's default profile; set `profile` explicitly to use a different preconfigured profile. Use `remote-reference` for an explicit registry destination:

```yaml
- uses: doomerlabs/actions/push@v1
  with:
    cli-version: 2026.10.17
    auth-mode: existing
    remote-reference: ghcr.io/acme/dockerfile:0.1.0
```

For hosted pushes, `repository-name` overrides the remote name independently of the name in `adversary.yaml`. It may be nested, such as `go/security`, and is always rooted under the authenticated team namespace (`adversarylabs/go/security`). A value already rooted at that same namespace is not duplicated. `library/*` is reserved for server-side official and partner promotion. The action combines `registry-host` (default `registry.doomer.ai`), `registry-namespace`, the repository name, and the packaged manifest version. Set `push-latest: true` to push the same digest under `latest` as well. Use `remote-reference` instead when the complete versioned destination must be supplied explicitly; it cannot be combined with `repository-name`.

### Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `cli-version` | no | `2026.10.17` | Exact Doomer CLI release tag. |
| `path` | no | `.` | Adversary project directory. |
| `builder` | no | `local` | `local` or `docker` package builder. |
| `install-dependencies` | no | `true` | Install dependencies from a supported lockfile before local packaging. Set to `false` when already installed; ignored by the Docker builder. |
| `name` | no | — | Local artifact-name override. |
| `remote-reference` | no | — | Fully qualified OCI destination. |
| `repository-name` | no | — | Remote repository name within `registry-namespace`; preserves the packaged version as its tag. |
| `push-latest` | no | `false` | Also push the same artifact with the `latest` tag. |
| `api-url` | no | hosted API | API endpoint used for login and registry token exchange. |
| `profile` | no | `push-action` for token/OAuth; CLI default for existing | CLI credential profile. |
| `auth-mode` | no | `auto` | `auto` uses a supplied token or otherwise OIDC; `oidc` requires GitHub Actions or Depot CI identity; `token`, `oauth`, and `existing` select those explicit flows. |
| `token` | with token auth | — | Service-account token supplied through a CI secret. For v1 compatibility, supplying it without `auth-mode` selects token auth. |
| `client-name` | no | `Doomer push action` | Name shown on the OAuth device-approval screen. |
| `registry-host` | no | — | Registry host override. |
| `registry-namespace` | with token auth* | — | Team registry namespace. May be omitted when `remote-reference` is explicit. |

### Outputs

| Output | Description |
| --- | --- |
| `reference` | Canonical pushed registry reference. |
| `digest` | Pushed OCI image manifest digest. |
| `manifest-digest` | Pushed adversary-manifest referrer digest. |
| `local-reference` | Canonical reference produced by the package step. |
| `latest-reference` | Pushed `latest` reference when `push-latest` is enabled. |
| `namespace-signature-digest` | Platform-issued namespace signature referrer digest for a hosted private publish; empty for external or public repositories. |
| `namespace-trust-digest` | Platform-endorsed team trust referrer digest for a hosted private publish; empty for external or public repositories. |

## Submit a hosted review

`doomerlabs/actions/review@v1` installs `doomerlabs/doomer` **2026.10.17** by default and executes `doomer review`. Hosted project settings select the model and reviewers; no model-provider secrets or local adversary installation are required.

```yaml
name: Doomer review
on:
  pull_request:
permissions:
  contents: read
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - name: Submit hosted review
        id: review
        uses: doomerlabs/actions/review@v1
        with:
          project: your-project-slug
          token: ${{ secrets.DOOMER_REVIEW_TOKEN }}
      - name: Report submission
        env:
          REVIEW_ID: ${{ steps.review.outputs.review-id }}
          STATUS: ${{ steps.review.outputs.status }}
        run: printf 'Review %s (%s)\n' "$REVIEW_ID" "$STATUS"
```

The action reviews the tree actually checked out, including tracked edits and non-ignored untracked files. Check out the PR head explicitly rather than GitHub's synthetic merge commit, and fetch the PR base commit. The action defaults `base` to the pull request's base SHA; other events use the CLI's baseline inference. Set `base` to override either behavior. The CLI's snapshot size and file-type restrictions apply.

The current snapshot API requires a service-account token with `registry:push` scope, even though this action does not publish an adversary. Hosted reviews must be enabled for the project. Token mode uses an isolated temporary configuration directory and removes it on exit. `auth-mode: existing` uses a preconfigured runner login, optionally selected with `profile`, without modifying that login. Snapshot submissions currently reject OIDC CI credentials, so the legacy action's OIDC pull login cannot be reused here. Fork PR workflows need an explicitly authorized credential strategy; ordinary fork PRs do not receive repository secrets.

**Submission is asynchronous.** A successful step means the server accepted the snapshot, not that the review passed or completed. CLI 2026.10.17 has no review wait/status or review-comment command. This action does not post GitHub comments, resolve threads, return findings, or implement `fail-on-findings`. Those capabilities require a follow-up CLI/API integration; the legacy local review flags cannot be passed to `doomer review`.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `cli-version` | no | `2026.10.17` | Exact release from `doomerlabs/doomer`. |
| `project` | yes | — | Hosted project slug or ID. |
| `path` | no | `.` | Directory in the Git worktree to upload. |
| `base` | no | PR base SHA or CLI default | Local baseline ref or commit. |
| `auth-mode` | no | `token` | `token` or `existing`. |
| `token` | with token mode | — | Service-account token supplied as a secret. |
| `profile` | no | Selected CLI profile | Only for `existing` mode. |
| `api-url` | no | CLI/profile default | API endpoint override. |
| `timeout-minutes` | no | `10` | Snapshot capture and submission deadline, not a hosted execution deadline. |

| Output | Description |
| --- | --- |
| `review-id` | Submitted hosted review ID. |
| `status` | Server status when the snapshot was submitted. |
| `result-file` | Submission JSON file; does not contain completed review findings. |

### Migrating from `run`

Change `uses: doomerlabs/actions/run@v1` to `uses: doomerlabs/actions/review@v1`, select a hosted `project`, and supply a suitable token or existing login. Remove legacy local-execution inputs such as `adversaries`, model credentials, registry pull settings, and GitHub comment controls. The unsupported `run` action has been removed. Workflows that depend on completed findings or GitHub comments need a separate integration until those hosted capabilities are available. The new action path becomes available on `@v1` when a release containing this change is published; before then, test with this branch's commit SHA.

## Security model

- **Push** builds the target source before authentication. Use reviewed code and protected release refs. Registry authority comes from the supplied credential flow.
- **Review** uploads a source snapshot to the configured hosted project. Token mode uses an isolated temporary CLI configuration and removes it after submission or failure. Existing mode preserves the runner's login.
- The current snapshot API requires a service-account token with `registry:push` scope; it does not support the publishing action's OIDC exchange.
- CLI release archives are checksum-verified. Pin `cli-version` and the action ref when exact toolchain reproducibility is required.
- Neither action requires write permission for the caller repository.

## Development

### Releasing the actions

Push a new immutable `vMAJOR.MINOR.PATCH` tag from reviewed `main`. The release
workflow tests that tagged commit, installs its default CLI, updates and verifies
the moving major tag (`v1` for a `v1.x.x` release), then publishes the GitHub
release. A failed major-tag update prevents release publication. Merging to
`main` alone does not release the actions.

To retry publication for an existing tag, dispatch `update-major-tag.yml` with
the `tag` input. Reruns preserve existing releases; older tags cannot move the
major tag backwards.

Run the deterministic shell test suite locally:

```bash
bash test/test.sh
```

The tests use a local release archive and a fake CLI; they do not contact Doomer or push artifacts.
