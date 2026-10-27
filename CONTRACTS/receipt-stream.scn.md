# SCN: receipt-stream

**3 channels** reply `{site}:res:{id}` (s, caller) · RECEIPT `{site}:gnode:receipts:{env}` stream (30 d, observers) · command `{site}:gnode:unified:{env}`. Receipt = metadata + ref (`bref`, `bh`=sha256 body), NEVER body. Signed ⇒ trustworthy in commons (provenance, not secrecy).

**Producers** (own key each; `signer` = who wrote it): gnode-daemon after every keyed reply (fast + ordered/batch lane; `st` ok|failed; key `/etc/geodineum/components/gnode-daemon/receipt_signing.key`, `GNODE_RECEIPT_KEY_FILE`) · COMMS terminal delivery (`cmd=comms.deliver`, `cid`=message stream id, `st`=delivery status; key `/var/lib/geodineum-comms/receipt_signing.key`) · gNode-Client PHP `Receipt\ReceiptEmitter` (wired by a PHP producer). FAIL-CLOSED on signing (no key/sign error ⇒ no row; never unsigned); best-effort on delivery (never fails the work).

**Signed bytes** `name=value\n` × `v alg cid cmd st e ss sn ts bref bh pid fid` in that order, absent optional = empty. `sig`=Ed25519 hex over them; `alg` inside ⇒ no downgrade; unknown/empty alg ⇒ fail. Unsigned extras: `wait_ms work_ms model`. Wire: `e pid fid` omitted when absent. `v`=1.

**Registry** HASH `{topology_ns}:gnode:receipt_pubkeys`: field `signer` (sha256(pubkey)[0:8] hex) → `<alg>:<pubkey hex>`; each producer HSETs its own at start. Unresolvable signer ⇒ unverifiable ≠ valid.

**Trim** each producer `XTRIM MINID ~ now−30d` after XADD.

**Conformance** `receipt-vectors.json` byte-identical in every producer (gNode `daemon/tests/`, COMMS `tests/`, gNode-Client `tests/`); no shared code across languages ⇒ vectors ARE the contract; format change ⇒ all copies, one commit.
