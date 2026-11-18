#!/bin/bash
set -euo pipefail
systemctl enable --now petcare-backend
systemctl restart petcare-backend
systemctl reload nginx || systemctl restart nginx
