# platform
Shared CI, release and platform standards for urzuahq

The standard is [RFC-1](docs/rfc/RFC-1-the-org-s-ci-and-release-standard.md). Reusable workflows will live
in `.github/workflows/` and composite actions and scripts in `ci/`, built in the order RFC-1 sets.
Call them at a full commit SHA.
