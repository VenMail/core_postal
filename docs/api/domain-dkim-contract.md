# Domain DKIM API contract

The Domains API returns an explicit public payload for `get`, `find_by_name`,
`list`, `domain`, `verify`, and `update_single_dkim`. Consumers may rely on
the top-level `id`, `name`, `dkim_identifier`, `dkim_record`, and
`dkim_record_name` fields. `dkim_record` is always derived from the stored
private key; a caller-supplied record is never trusted.

Those documented fields are the supported compatibility contract. Historical
generic model serialization exposed internal fields such as `server_id` and
`uuid`; clients should use the documented `id` and `name` instead. This
deprecation does not restore bulk rotation or generic private-key disclosure.

`dkim_private_key` is never part of the default payload and never appears in
generic `Domain#as_json` or `Domain#serializable_hash` output. It is returned only when
`include_private_key=true` is requested by a credential for the server that
directly owns that domain. Shared organization domains can be read and
verified by servers in that organization, but cannot export their private key,
be deleted, or have their DKIM material changed through a server credential.
Domains belonging to another server are treated as not found.

New generated keys, explicit regenerations, and BYODKIM updates require at
least a 2048-bit RSA private key. Existing persisted 1024-bit keys remain
unchanged until a caller explicitly repairs that one domain through
`update_single_dkim`; the API never performs a blanket key rotation. The
legacy `update_dkim` bulk endpoint is deliberately disabled.

New selector suffixes must be DNS-safe alphanumeric/underscore/hyphen values.
Template text such as `%dkim_data%` is rejected before persistence. If a
legacy row contains an invalid selector, public API fields fail closed instead
of returning that text or a usable DNS record name; regenerate that domain
explicitly to repair it.

The initial Core signing-key bootstrap follows the same 2048-bit minimum, but
does not replace an existing signing key. Rotating an existing key remains an
explicit maintenance operation.
