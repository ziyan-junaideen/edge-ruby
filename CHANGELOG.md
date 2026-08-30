# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from 1.0.0; until then the public API may change in any release.

## [Unreleased]

### Added

- Vendored API contract: `contract/manifest.yml` derived from the Edge Phoenix
  source, a cross-check snapshot of `openapi.json`, and provenance for both.
- `contract/bin/extract_manifest.rb`, which regenerates the manifest and
  reports what it cannot resolve rather than guessing.
- `docs/pagination.md`, recording production's unpaginated behaviour separately
  from the unmerged cursor proposal.
- `docs/release-blockers.md`, recording the API-side gaps that constrain what
  this client may expose.
- Package identity: name, namespace, MIT license and unofficial positioning.
