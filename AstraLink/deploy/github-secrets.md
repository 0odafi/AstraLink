# GitHub Secrets For Auto Publish

Add these repository secrets:

- `DEPLOY_HOST` - server IP or domain
- `DEPLOY_USER` - SSH user (for example `deploy`)
- `DEPLOY_PORT` - usually `22`
- `DEPLOY_SSH_KEY` - private SSH key (ed25519 recommended)
- `DEPLOY_RELEASES_PATH` - server path for releases, for example `/opt/astralink/releases`
- `RELEASES_PUBLIC_BASE_URL` - public URL mapped by nginx, for example `https://your-domain.example/files`
