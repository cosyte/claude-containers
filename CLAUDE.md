# Notes for Claude Code sessions working in this repo

This repo builds the container image, its launcher and its session tools. Read `CONTRIBUTING.md`
first; `README.md` is load-bearing operator documentation, and `docs/` holds the long sections.

- **Gate, one line:** `npm run lint` (`make lint` plus the no-em-dash check) and `npm test` (the
  unit suites) on every PR, the same as CI's required checks `ci` and `no-emdash`; add `make smoke`
  (builds and runs the image, not in CI) before merging anything that touches the Dockerfile, the
  entrypoint or launch. The first pair is the fast tier, the three together the full tier.
- **Public repo:** placeholder names only (`me/x`, `myproj`, "the owner"); never a person's name,
  a private repository, a device, an email, a LAN address or an account ID. No em dashes anywhere.
- **Secrets never enter a file, an issue, a PR or a log:** `GH_TOKEN`, `.credentials.json`, SSH keys.
- One logical change per PR, docs in the same PR, imperative commit subjects (`fix(entrypoint): ...`).
