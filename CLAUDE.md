# Notes for Claude Code sessions working in this repo

This repo builds the container image, its launcher and its session tools. Read `CONTRIBUTING.md`
first; `README.md` is load-bearing operator documentation, and `docs/` holds the long sections.

- **Gate, one line:** `npm run lint` (`make lint` plus the no-em-dash check) and `npm test` (the
  unit suites) on every PR, the same as CI's required checks `ci` and `no-emdash`. CI's `smoke`
  job builds the image and runs `test/smoke.sh` when the Dockerfile, the entrypoint, `bin/`,
  `claude-config/`, `scripts/`, the Makefile, compose or `ci.yml` change (10 to 20 minutes, never
  in a session's gate; sessions have no Docker). `make smoke` locally is optional.
- **Public repo:** placeholder names only (`me/x`, `myproj`, "the owner"); never a person's name,
  a private repository, a device, an email, a LAN address or an account ID. No em dashes anywhere.
- **Secrets never enter a file, an issue, a PR or a log:** `GH_TOKEN`, `.credentials.json`, SSH keys.
- One logical change per PR, docs in the same PR, imperative commit subjects (`fix(entrypoint): ...`).
