# Distribution — signed binaries on GitHub Pages

`.github/workflows/Release.yml` builds `duck_diff` for every native platform on
each GitHub Release, signs each binary, and publishes them to GitHub Pages as a
DuckDB extension repository:

```
https://<owner>.github.io/duck_diff/<duckdb_version>/<platform>/duck_diff.duckdb_extension.gz
```

Users install without building (see [Installing](#installing-as-a-user)).

> **Note on signing.** Stock DuckDB only trusts DuckDB's own key, so an extension
> signed with *your* key still requires `allow_unsigned_extensions = true`. The
> signature here provides integrity/provenance, not flag-free loading. The only
> way to drop that flag is the DuckDB community-extensions pipeline (which signs
> with DuckDB's key after a review).

## One-time setup

### 1. Generate a signing key

```sh
openssl genrsa -out private.pem 2048
openssl rsa -in private.pem -pubout -out public.pem   # keep for verification; optional
```
Keep `private.pem` **out of the repo** (it's the secret). `public.pem` is safe to
share if you want consumers to be able to verify signatures.

### 2. Store the private key as a repository secret

GitHub → repo **Settings → Secrets and variables → Actions → New repository
secret**:

- **Name:** `DUCKDB_EXTENSION_SIGNING_PK`
- **Value:** the full contents of `private.pem` (including the
  `-----BEGIN/END …-----` lines)

If the secret is absent the workflow still publishes, just with an unsigned
(zeroed) signature slot.

### 3. Enable GitHub Pages from Actions

GitHub → repo **Settings → Pages → Build and deployment → Source = GitHub
Actions**.

## Releasing

Cut a GitHub Release (e.g. tag `v0.1.0`). The workflow:

1. builds `duck_diff` against the pinned DuckDB version for each platform;
2. signs each binary by overwriting its 256-byte signature slot;
3. publishes the tree to GitHub Pages.

`workflow_dispatch` lets you run it manually too.

> The pinned DuckDB version lives in both `Release.yml` and
> `MainDistributionPipeline.yml` (`DUCKDB_VERSION` / `duckdb_version`). Bump them
> together. Pages publishes the versions built in the *latest* run, so to serve
> multiple DuckDB versions you'd merge old content into `_site` before deploying.

## Installing (as a user)

DuckDB version and platform must match a published build.

```sql
SET custom_extension_repository = 'https://<owner>.github.io/duck_diff';
SET allow_unsigned_extensions = true;   -- required: signed with a third-party key
INSTALL duck_diff;
LOAD duck_diff;

FROM table_diff('a', 'b', pk := 'id');
```
