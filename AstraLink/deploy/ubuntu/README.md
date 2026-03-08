# Ubuntu 24.04 Deployment (AstraLink)

## 1. What you need on server

- Ubuntu 24.04 LTS
- Public DNS/domain pointing to server
- Open ports `22`, `80`, `443`
- User with sudo privileges
- GitHub repository with Actions enabled

## 2. Initial setup

Copy repository to server and run:

```bash
sudo bash deploy/ubuntu/setup_server.sh
```

## 3. Configure backend service

```bash
sudo cp deploy/ubuntu/api.env.example /etc/astralink/api.env
sudo nano /etc/astralink/api.env
```

Copy service file:

```bash
sudo cp deploy/ubuntu/astralink-api.service /etc/systemd/system/astralink-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now astralink-api
sudo systemctl status astralink-api
```

Install backend dependencies into server venv:

```bash
sudo -u astralink /opt/astralink/venv/bin/pip install --upgrade pip
sudo -u astralink /opt/astralink/venv/bin/pip install -e /opt/astralink
sudo systemctl restart astralink-api
```

## 4. Configure nginx

```bash
sudo cp deploy/ubuntu/nginx.astralink.conf /etc/nginx/sites-available/astralink
sudo ln -sf /etc/nginx/sites-available/astralink /etc/nginx/sites-enabled/astralink
sudo nginx -t
sudo systemctl reload nginx
```

Enable HTTPS:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d volds.ru
```

## 5. Releases path

The auto-publish pipeline uploads files into:

- `/opt/astralink/releases/astralink/windows/<version>/...`
- `/opt/astralink/releases/astralink/android/<version>/...`
- `/opt/astralink/releases/manifest.json`

Public URL base in this nginx config is:

- `https://volds.ru/files`

## 6. SSH for GitHub Actions

Generate key pair on your PC:

```powershell
ssh-keygen -t ed25519 -C "astralink-release" -f $env:USERPROFILE\.ssh\astralink_release
```

Add public key to server user (`deploy` or your sudo user):

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat astralink_release.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Set GitHub secret `DEPLOY_SSH_KEY` from `deploy/github-secrets.md`.
