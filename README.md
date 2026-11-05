# maas-api

Dedicated public repository for the standalone `maas-api` service used by EnMaaS.

The service source lives under [`maas-api/`](maas-api/). It was extracted from
the `maas-api` subtree of
[`opendatahub-io/models-as-a-service`](https://github.com/opendatahub-io/models-as-a-service),
preserving the original commit history and the upstream-relative `maas-api/`
path so changes can be cherry-picked back upstream.

## Base

This repository starts from
[`yossiovadia/models-as-a-service:feat/standalone-api-key-mode`](https://github.com/yossiovadia/models-as-a-service/tree/feat/standalone-api-key-mode)
at commit `5fc83feb` (`feat: support standalone api key mode`).

The EnMaaS deployment profile is being added on top of that base while keeping
the upstream default behavior available.

## EnMaaS profile

Set `MAAS_DEPLOYMENT_PROFILE=enmaas` with
`MAAS_SUBSCRIPTION_MODE=standalone` to run without Kubernetes/CRD access. This
profile reads `DATABASE_URL` or `DB_CONNECTION_URL` from the environment,
serves plain HTTP metrics, and exposes only the EnMaaS key-management API.
The default `upstream` profile preserves the full old maas-api behavior.

## Layout

- `maas-api/` — Go service, schema, API contract, and container build
- `LICENSE` — Apache License 2.0
- `NOTICE` — upstream attribution

## Upstream references

- `upstream` — `opendatahub-io/models-as-a-service`
- `yossi` — `yossiovadia/models-as-a-service`

EnMaaS-specific changes should remain inside `maas-api/` and stay compatible
with cherry-picking to the upstream repository.

## Secret scanning

`maas-api/vendor/` contains upstream dependency documentation, including
example database connection strings. These are not credentials and are excluded
from repository secret scanning. First-party source under `maas-api/` remains
in scope for secret scanning.
