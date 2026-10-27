# Downstream patches

Our changes to upstream https://github.com/wanderers-guide/wanderers-guide, kept as patch files instead of a fork.
`apply-wg-patches.sh` rebuilds a local `deployed` branch as upstream `origin/main` plus every patch set here.

| Patch set | What it does | Upstream status |
|---|---|---|
| security-function-auth | Require a user JWT or API key on every function except public content reads; admin Players functions and audit read model | Held back (security fix) |
| fix-mine-mod-live-snapshot | Accept live Programmer description and Auto Spellshape source metadata in the mine-mod guard | Report as issue upstream |

When upstream fixes something, delete that patch set. Full history backup: D:\Backups\wanderers-guide-private-20261027.bundle (all branches of the old private fork).