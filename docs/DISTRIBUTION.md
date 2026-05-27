# Distribution — signed binaries on GitHub Releases

`.github/workflows/Release.yml` builds `duck_diff` for every native platform on
each GitHub Release, signs each binary, and attaches the signed
`.duckdb_extension` files (plus `SHA256SUMS`) to the release as assets.

Users download the file for their platform and `LOAD` it — there is no
`INSTALL … FROM` (that would require a hosted extension repository); this is the
simpler, fully self-contained route.

> **Signing note.** Stock DuckDB only trusts DuckDB's own key, so a binary
> signed with *your* key still requires `allow_unsigned_extensions` (the
> `-unsigned` launch flag). The signature provides integrity/provenance, not
> flag-free loading.

## One-time setup

### 1. Generate a signing key

```sh
openssl genrsa -out private.pem 2048
openssl rsa -in private.pem -pubout -out duck_diff-signing-key.pub   # public half (committed)
```
Keep `private.pem` out of the repo.

### 2. Store the private key as a repository secret

GitHub → **Settings → Secrets and variables → Actions → New repository secret**:

- **Name:** `DUCKDB_EXTENSION_SIGNING_PK`
- **Value:** the full contents of `private.pem`

If the secret is absent the workflow still attaches binaries, just with an
unsigned (zeroed) signature slot.

## Releasing a new version

The version **is the git tag** — there's no version file to edit. The build
stamps the extension version from the tag (`git describe`). So a release is:

1. **Land your changes on `main`** (merge the PR, or push).
2. **Pick the next version tag**, SemVer-style `vMAJOR.MINOR.PATCH`:
   - patch (`v0.1.1`) — bug fixes;
   - minor (`v0.2.0`) — new, backward-compatible features;
   - major (`v1.0.0`) — breaking changes.
   Check the latest with `gh release list` (or the Releases page) and increment.
3. **Cut the release** (tag + publish in one step):
   ```sh
   git checkout main && git pull
   gh release create v0.2.0 --target main --title "duck_diff v0.2.0" --notes "see workflow"
   ```
   (Or GitHub UI → **Releases → Draft a new release** → create tag `v0.2.0` on
   `main` → **Publish**.)
4. **Done** — publishing fires `Release.yml`, which builds every platform, signs
   each binary, attaches them as
   `duck_diff-<duckdb_version>-<platform>.duckdb_extension` + `SHA256SUMS`, and
   rewrites the release notes with install instructions, the source commit, and
   the checksums. Watch it with `gh run watch` if you like.

> **Re-cutting the same version:** if a release run fails and you've fixed it,
> `gh release delete vX.Y.Z --yes --cleanup-tag` then recreate it.
>
> **DuckDB target** (separate from the extension version) is pinned in
> `Release.yml` and `MainDistributionPipeline.yml` (`DUCKDB_VERSION` /
> `duckdb_version`); bump both together only when moving to a new DuckDB
> release. `workflow_dispatch` runs the build/sign manually but won't touch
> release notes (that step is gated to real release events).

## Installing (as a user)

Download the `*.duckdb_extension` matching your DuckDB version and platform from
the release assets and **save it as `duck_diff.duckdb_extension`** — DuckDB
derives the extension name and entrypoint from the filename, so the name matters.
It's signed with a third-party key, so launch with `-unsigned`:

```sh
curl -L -o duck_diff.duckdb_extension \
  https://github.com/<owner>/duck_diff/releases/download/v0.1.0/duck_diff-v1.5.2-osx_arm64.duckdb_extension
duckdb -unsigned
```
```sql
LOAD 'duck_diff.duckdb_extension';
FROM table_diff('a', 'b', pk := 'id');
```
From a client library, enable unsigned extensions in the connection config (e.g.
Python: `duckdb.connect(config={'allow_unsigned_extensions': True})`).

## Verifying a download

Each release ships `SHA256SUMS` (also inlined in the notes) and is signed with
the key whose public half is committed at
[`duck_diff-signing-key.pub`](../duck_diff-signing-key.pub):

```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAr/53PojMEHkMQrGKNccE
dEibup8q5EiS5XSZT7zWcqB1KWurGWX4MI8tQ368TRN93N8cqDdEYfXlSKYy2jYO
kzBKTN2rJ17EFfHUxeF65yXI5TuX7Do31sxFWQ7pVyGfKdNWydvzYnsW0tsVscvE
nHsbqG1ZheaB97qWBVg8GQMlNrYr/7aciIUoxmmeqc2NlL8wRXu3I1P2zur5tJEz
ZhpG5i6xBlwurBt6Uz96x6DE4m1VVSTMjK+8H0WvcmPXXIhN4+iEO/Guj4Lhy82B
cRhjdKXyVWVNBehqHLd9hV7i44Gt2RDBrrPWDKgEPblajXpyz3EOTeYG3rmLDDgb
9QIDAQAB
-----END PUBLIC KEY-----
```

**Checksum:**
```sh
sha256sum -c SHA256SUMS   # with the downloaded files in the same directory
```

**Signature.** The signature is the file's **last 256 bytes**; the signed
payload is the SHA256 composite of everything before it (1 MiB chunks each
hashed, then the concatenation hashed — DuckDB's `compute-extension-hash.sh`):

```sh
F=duck_diff-v1.5.2-osx_arm64.duckdb_extension
size=$(wc -c < "$F")
head -c $((size - 256)) "$F" > body
tail -c 256             "$F" > sig
: > chunks
split -b 1M body seg_
for f in seg_*; do openssl dgst -binary -sha256 "$f" >> chunks; rm "$f"; done
openssl dgst -binary -sha256 chunks > hash
openssl pkeyutl -verify -pubin -inkey duck_diff-signing-key.pub \
  -sigfile sig -in hash -pkeyopt digest:sha256
# -> Signature Verified Successfully
```
