# GitHub Secrets For Auto Publish

With current project configuration, only one secret is required:

- `DEPLOY_SSH_KEY` - private SSH key used to connect to `root@87.120.84.205`.

Important:

- Do NOT paste a fingerprint (`SHA256:...`) or `.pub` key.
- Secret must contain the PRIVATE key (`-----BEGIN ... PRIVATE KEY-----` ... `-----END ... PRIVATE KEY-----`).
- Key must be without passphrase for CI.

You can provide `DEPLOY_SSH_KEY` in either format:

1. Raw multiline private key (recommended)
2. Base64 of private key bytes

PowerShell (create base64 from key file):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\\.ssh\\astralink_deploy_nopass"))
```
