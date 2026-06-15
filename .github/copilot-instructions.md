# Copilot Instructions — Fido2Ssh

## Repository purpose

PowerShell module (`Fido2Ssh`) that wraps `ssh-keygen` and `ssh-add` to manage
FIDO2-backed SSH keys (resident / discoverable and non-resident / software
passkeys) stored on a hardware authenticator (YubiKey, etc.).

---

## Module structure

```
Fido2Ssh/
  Fido2Ssh.psd1        # module manifest — version, GUID, author, description
  Fido2Ssh.psm1        # loader: dot-sources Private/*.ps1 then Public/*.ps1;
                       #   exports exactly the functions whose names match
                       #   the Public/ file basenames
  Private/
    Get-Fido2CanonicalName.ps1   # Get-Fido2KeyFingerprint, Get-Fido2KeyThumbprint,
                                 #   Get-Fido2CanonicalName — shared helpers, not exported
    Get-Fido2DefaultSshDirectory.ps1
    Resolve-Fido2PublicKeyPath.ps1
    Test-Fido2WindowsElevation.ps1
  Public/
    Enable-Fido2SshKeys.ps1
    Get-Fido2SshKey.ps1
    Import-Fido2SshKey.ps1
    New-Fido2SshKey.ps1
    Publish-Fido2SshKey.ps1
    Publish-Fido2SshKeyToAzureVM.ps1
    Remove-Fido2SshKey.ps1
```

**Rule**: Every file added to `Public/` is automatically exported (by file
basename). Every file added to `Private/` is available to all public functions
but never exported.

---

## Key filename conventions

Both key types share the same general structure; the presence or absence of
`_rk` distinguishes them:

| Type | Pattern |
|------|---------|
| Resident (discoverable) | `id_<typeSuffix>_rk[_<label>]_<thumbprint>` |
| Non-resident (software) | `id_<typeSuffix>_sk[_<label>]_<thumbprint>` |

Where:
- `<typeSuffix>` is `ed25519_sk` or `ecdsa_sk` (underscores, not hyphens).
- `<label>` is the part after `ssh:` in the FIDO application string; may be
  absent for unlabelled keys.
- `<thumbprint>` is 12 lowercase alphanumeric characters derived from the
  SHA256 fingerprint (see `Get-Fido2KeyThumbprint`).

`Get-Fido2CanonicalName` builds these names. Its `Resident` bool parameter
controls the presence of `_rk` (default `$true`).

The underscore `_` is used as a token boundary — **labels must not contain
underscores** (enforced in `New-Fido2SshKey` with `^[A-Za-z0-9.-]+$`).

---

## PowerShell coding conventions

- `Set-StrictMode -Version Latest` is active at module scope.
- Public functions that mutate state use `[CmdletBinding(SupportsShouldProcess = $true)]`
  and `$PSCmdlet.ShouldProcess(...)` before every destructive action.
- `Remove-Fido2SshKey` is declared `ConfirmImpact = 'High'`.
- Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`)
  is required in every Public function.
- Use `Write-Host` for user-facing progress/result messages, `Write-Verbose`
  for diagnostic detail, `Write-Warning` for non-fatal issues.
- PowerShell 5.1 (Desktop edition) compat: avoid `$IsWindows` without a
  fallback guard; use the `cmd.exe` shim for `ssh-keygen` calls with empty
  `-N ""` args (Desktop silently drops bare empty-string args).
- Temporary directories are always cleaned up in a `try/finally` block with
  `Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`.

---

## Key type semantics

### Resident keys (default)

- Created with `ssh-keygen -O resident`.
- Credential lives on the authenticator; file on disk is a handle only.
- Recoverable via `Import-Fido2SshKey` (`ssh-keygen -K`).
- `Import-Fido2SshKey` requires an **elevated** session on Windows (raw HID
  access; non-elevated falls through to the WebAuthn API which lacks
  credential enumeration).

### Non-resident (software) passkeys

- Created **without** `-O resident`.
- The FIDO application string (`ssh:<label>`) is still passed so different
  non-resident keys on the same authenticator produce distinct key material.
- Private key handle lives only in the file on disk — if lost, the credential
  is gone and cannot be recovered from the authenticator.
- `Remove-Fido2SshKey` skips non-resident keys by default and prints a
  warning; the `-IncludeNonResident` switch opts in.
- After deleting non-resident key files, users must also clean up the
  corresponding passkey from the authenticator's credential store.

---

## README files

| File | Audience | Style |
|------|----------|-------|
| `README.md` (repo root) | GitHub visitors, developers | Full docs: prerequisites, all commands with parameter tables, workflow examples, security notes, CI/CD |
| `Fido2Ssh/README.md` | PSGallery page | **Minimal**: 1-paragraph description, Install snippet, command list, link to GitHub repo |

When adding a new public command or parameter, update **both** files:
- Root README: full description + parameter table + examples.
- `Fido2Ssh/README.md`: one bullet in the command list only.

---

## CI/CD

- `.github/workflows/ci.yml` — runs PSScriptAnalyzer + module import validation
  on every push/PR to `main` (Windows and Linux runners).
- `.github/workflows/publish.yml` — publishes to PSGallery on `v*.*.*` tag push
  or manual `workflow_dispatch`. Stamps the version into `Fido2Ssh.psd1` via
  `Update-ModuleManifest` before calling `Publish-Module`.
- PSGallery API key lives in a repository secret `PSGALLERY_API_KEY` inside the
  `PSGallery` GitHub Environment.

---

## Releasing

```powershell
git tag v0.x.y
git push origin v0.x.y
```

The publish workflow handles everything else.
