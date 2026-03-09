#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/ubuntu/update_git_deploy.sh"
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/astralink}"
APP_USER="${APP_USER:-astralink}"
APP_GROUP="${APP_GROUP:-astralink}"
BRANCH="${BRANCH:-master}"

if [[ ! -d "${APP_DIR}/.git" ]]; then
  echo "${APP_DIR} is not a git repository. Run enable_git_deploy.sh first."
  exit 1
fi

git -C "${APP_DIR}" fetch origin
git -C "${APP_DIR}" checkout "${BRANCH}"
git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"

if [[ -x "${APP_DIR}/venv/bin/pip" ]]; then
  sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install --upgrade pip
  sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install -e "${APP_DIR}"
fi

chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

systemctl restart astralink-api

echo
echo "Update complete."
echo "Current revision:"
git -C "${APP_DIR}" rev-parse --short HEAD
