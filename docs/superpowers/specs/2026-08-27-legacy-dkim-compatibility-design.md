# Legacy DKIM Compatibility Design

## Problem

Core now requires RSA-2048 DKIM material everywhere. Persisted domains created before that policy, including `venmail.io`, still hold matching RSA-1024 private keys and DNS records. The key is usable and the published public key matches, but `api_public_dkim_payload` returns `invalid`, hides the record, and prevents DNS verification.

## Approved behavior

- Preserve persisted RSA-1024 private keys as backward-compatible legacy material.
- Return their derived selector and public DNS record through the existing `ready` contract so existing API clients continue to work.
- Include additive `key_bits` and `legacy` metadata for visibility.
- Validate their live DNS records with the same semantic DKIM comparison used for RSA-2048 records.
- Keep RSA-2048 mandatory for every newly generated, regenerated, or explicitly imported private key.
- Continue rejecting corrupt keys, public-only keys, and RSA keys below 1024 bits.
- Do not rotate selectors or key material automatically.

## Data flow

`Domain#api_public_dkim_payload` parses the persisted private key. A private RSA key of at least 1024 bits produces the existing public payload. Keys below 2048 bits are labeled `legacy: true`; 2048-bit or stronger keys are labeled `legacy: false`. `Domain#dkim_verified?`, the setup page, and DNS checks retain their existing `status == ready` behavior.

Write-time validation remains unchanged at RSA-2048. This creates a deliberate boundary: old stored material remains readable and verifiable, while any replacement must meet the current standard.

## Verification

- Regression test: a persisted RSA-1024 key yields a ready legacy payload and can pass a matching DNS check.
- Existing validation test: assigning a new RSA-1024 key remains invalid.
- Existing generation test: new and regenerated keys remain RSA-2048.
- Existing corrupt-key and mismatched-DNS tests remain green.
- Production verification: recheck `venmail.io` without changing its selector/key and confirm its stored public-key hash still matches live DNS.
