# Security policy

## Supported version

Only the current `main` branch is maintained.

## Reporting

Do not open a public issue for a suspected credential or sensitive identifier.
Use GitHub's private vulnerability reporting feature when it is enabled. If it
is unavailable, contact the repository owner through the public profile without
including the sensitive value.

## Repository security model

This repository intentionally contains no Azure credentials or live IDs.
Authenticated workflows should use GitHub OpenID Connect with environment
protection and short-lived Azure tokens. Long-lived client secrets, exported
ARM output, and local `*.local.bicepparam` files are excluded from version
control.
