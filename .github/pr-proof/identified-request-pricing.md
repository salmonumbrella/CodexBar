# Codex identified-request pricing proof

These aggregate-only captures come from the completed `codexbar cost --provider codex --identified-only --format json --days 1 --identified-end 1793230920000 --remote <redacted SSH peer>` runs. Request identities, hostnames, local paths, and raw history rows were redacted. The CLI product code was built from `ebf930f62539b815dca0381554c0299cedd10c97`; PR head `bbd3dd495c09f28b168df02f23730c964077342d` only consolidates tests, so it contains the same product code.

## Real local history plus SSH source

```json
{
  "exitCode": 0,
  "allSourcesAvailable": true,
  "partial": true,
  "sources": [
    { "source": "local", "schemaVersion": 2, "requestCount": 2745 },
    { "source": "remote", "schemaVersion": 2, "requestCount": 28 }
  ],
  "subtotal": {
    "kind": "identified-request-subtotal",
    "requestCount": 2745,
    "totalTokens": 307456858,
    "costUSD": 81.4315061399999,
    "unpricedRequestCount": 0,
    "conflictCount": 0,
    "excludedCount": 0
  }
}
```

`partial` reflects incomplete history coverage; both sources were available and the remote requests overlapped the local identity set.

## Duplicate-copy and unknown-tier controls

```json
{
  "exitCode": 0,
  "allSourcesAvailable": true,
  "partial": false,
  "sources": [
    { "source": "local", "schemaVersion": 2, "requestCount": 28 },
    { "source": "remote", "schemaVersion": 2, "requestCount": 28 }
  ],
  "subtotal": {
    "kind": "identified-request-subtotal",
    "requestCount": 28,
    "totalTokens": 2957378,
    "costUSD": 0.7238776,
    "unpricedRequestCount": 0,
    "conflictCount": 0,
    "excludedCount": 0
  }
}
```

The same fixture with unrecorded/unknown tier evidence retained the complete request accounting and did not invent a price:

```json
{
  "exitCode": 0,
  "allSourcesAvailable": true,
  "partial": false,
  "sources": [
    { "source": "local", "schemaVersion": 2, "requestCount": 28 },
    { "source": "remote", "schemaVersion": 2, "requestCount": 28 }
  ],
  "subtotal": {
    "kind": "identified-request-subtotal",
    "requestCount": 28,
    "totalTokens": 2957378,
    "costUSD": null,
    "unpricedRequestCount": 28,
    "conflictCount": 0,
    "excludedCount": 0
  }
}
```

## Mixed-version peer controls

Each version-mismatch run exited `1` and reported partial results. The local subtotal remained available; the incompatible remote ledger was rejected. The old executable in both controls is the `0.82.1` development baseline (`5f93dc3`), which emits schema 1. These controls demonstrate schema-mismatch handling; they are not runs with a v0.82.0 CLI.

| Collector | Remote exporter | Local data retained | Remote result | Local subtotal |
| --- | --- | --- | --- | --- |
| New CLI | baseline schema-1 CLI (0.82.1 development) | Schema 2, 28 requests / 2,957,378 tokens | Unavailable | 28 requests / 2,957,378 tokens / USD 0.7238776 |
| baseline schema-1 CLI (0.82.1 development) | New CLI (schema 2) | Schema 1, 28 requests / 2,957,378 tokens | Unavailable | 28 requests / 2,957,378 tokens / no price |

## Persisted upgrade coverage

The local cache-upgrade regression uses the exact v0.82.0 parser hash `e5909f60274b2c47` in `CostUsageStoreTests`. `compatible predecessor parser hash adopts without rebuilding` seeds a predecessor snapshot with that hash, requires the upgraded snapshot to match the retained cache/history state, checks `rebuildCount == 0`, and resumes the saved scan cursor. This is the v0.82.0 upgrade evidence; no v0.82.0 CLI run is claimed here.

Previously recorded focused verification at the logic head passed 116 tests in 4 suites, including `CostUsageStoreTests`, and 41 tests in 3 suites, including `CodexRequestSubtotalTests`. Other relevant regressions cover `retained report migration preserves compatible rows and clears stale payload` and `optional pricing observation leaves ordinary rows and saved settings unchanged`. These checks cover cache/history and settings retention; they were not rerun for this evidence document.
