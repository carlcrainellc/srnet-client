# srnet-msgboard protocol v1 (phase 0)

Canonical bytes: `DOMAIN + "\n" + json.dumps(obj, sort_keys=True, separators=(",",":"), ensure_ascii=False)` (UTF-8).
Domains: `srnet-msgboard-post/v1`, `-checkpoint/v1`, `-delegation/v1`, `-pow/v1`, `-chain/v1` (never shared with the exit board).

## Post envelope
```json
{"post": {"v":1, "board":"demo", "author":"<hex Ed25519 author key>", "ts":1792000000,
          "body":"<=500 chars, NFC, no control chars except \\n \\t",
          "reply_to":"<post id>|null", "pow":{"bits":16,"salt":"…"}},
 "sig": "<hex Ed25519 over canonical(post domain, post)>", "id": "<post id>"}
```
- Exactly these fields; anything else is refused. Author key is a dedicated signing key, separate from the Session Router/Noise transport key.
- `id` = z-base32 of the first 16 bytes of SHA-256(canonical signed bytes). Same post = same id on every host.
- PoW: SHA-256(canonical(pow domain, post)) has ≥ `pow.bits` leading zero bits, and `pow.bits` ≥ host policy.
- Host accepts `ts` within −600 s / +60 s of its clock (replay window); an already-stored id is idempotent (`dup:true`); `board` must match (cross-board replay refused).
- Test vectors: `tests/vectors/posts-v1.json` (regenerate with `scripts/gen_vectors.py`).

## Log, chain, checkpoint
- `link_n = SHA-256("srnet-msgboard-chain/v1\n" + link_{n-1} + "\n" + n + "\n" + id_n)`, `link_0 = 64×"0"`.
- Checkpoint `{v, board, host, seq, head, issued, expires}` signed by the host key; re-signed at most every 60 s or on new entries; valid 3 h.
- Delegation `{v, board, root, host, issued, expires, policy}` signed by the board's (offline) root key. Clients pin only the root key.
- Client rules: verify delegation → checkpoint (sig, expiry, not from future) → no rollback (seq < pinned) / no equivocation (same seq, other head) → each entry's sig, id, seq continuity and link → final link == checkpoint head. Only a fully verified segment is committed; otherwise fail over to the next host.

## HTTP (JSON only, `nosniff`, CSP `default-src 'none'; sandbox`)
`GET /v1/info | /v1/delegation | /v1/checkpoint | /v1/log?since=N&limit≤500 | /v1/post/<id> | /v1/thread/<id>`, `POST /v1/submit` (≤16 KB).
Mirrors serve the same GET API with the primary's own signed checkpoint and delegation, so readers verify them identically.

## Phase 1 additions
- Checkpoint gains `policy` (SHA-256 of canonical(`srnet-msgboard-policy/v1`, policy)) and `rseq` (record count).
- Records (`GET /v1/records?since=N`): `mod` = host-signed `{v,board,host,action:hide|unhide,target_type:post|author,target,reason,ts}`
  (domain `srnet-msgboard-mod/v1`); `delete` = author-signed `{v,board,author,targets[≤50],ts}` (domain `srnet-msgboard-delete/v1`). `rid` = first 32 hex of SHA-256 of canonical bytes.
- Tombstone entries `{seq,id,link,tomb:{by:"delete",record}|{by:"retention"}}`; links cover ids only, so chains still verify.
- `POST /v1/delete`; `POST /v1/publish` (mirror only: `{delegation, checkpoint, policy, entries, records}`).
- New keys (first post < `new_key_age_s`) need `new_key_pow_bits` and obey `new_key_rate`.

## Typed platform
