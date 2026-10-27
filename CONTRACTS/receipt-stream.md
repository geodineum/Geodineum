# Receipt stream — the signed record of a command's outcome

A command's outcome travels on three channels, one per need:

| Channel | Key | Lifetime | Read by |
|---|---|---|---|
| Reply | `{site}:res:{id}` | seconds | the caller |
| **Receipt** | `{site}:gnode:receipts:{env}` (stream) | 30 days | observers, each with its own consumer group or cursor |
| Command | `{site}:gnode:unified:{env}` (stream) | — | the services that handle it |

A receipt is metadata and a reference, never the result body. It is signed, so it can sit on a
shared stream and still be trusted: provenance, not secrecy.

## Producers

| Producer | `cmd` | `cid` | `st` | Key file (private, never leaves the host) |
|---|---|---|---|---|
| gnode-daemon, after every keyed reply (fast lane and ordered/batch lane) | the command | the request id | `ok` \| `failed` | `/etc/geodineum/components/gnode-daemon/receipt_signing.key` (`GNODE_RECEIPT_KEY_FILE`) |
| Geodineum-COMMS, at each message's terminal delivery outcome | `comms.deliver` | the message's stream entry id | the delivery status (`sent`, `failed`, …) | `/var/lib/geodineum-comms/receipt_signing.key` |
| gNode-Client (PHP) `Receipt\ReceiptEmitter`, for a PHP producer that wires it | the caller's | the caller's | the caller's | the producer's own |

Each producer signs with its own key, so `signer` names who wrote the receipt. Signing is fail-closed: a
producer without a key, or whose signing fails, writes no receipt. An unsigned row is never written. A
receipt that cannot be delivered never fails the work it describes.

## Wire fields

| Field | Meaning | Signed |
|---|---|---|
| `v` | schema version, `1` | yes |
| `alg` | signature algorithm, `ed25519` | yes |
| `cid` | correlation id: joins request, reply and receipt | yes |
| `cmd` | the command or action | yes |
| `st` | outcome | yes |
| `e` | error text; absent when there is none (signed as empty) | yes |
| `ss` | producing site | yes |
| `sn` | producing node | yes |
| `ts` | completion time, ms since epoch | yes |
| `bref` | where the body lives (e.g. the reply key) | yes |
| `bh` | hex sha256 of the body | yes |
| `pid`, `fid` | parent and flow id (lineage), optional; signed as empty when absent | yes |
| `wait_ms`, `work_ms`, `model` | timing and model, optional | no |
| `sig` | hex signature | — |
| `signer` | first 8 bytes of sha256(public key), hex | — |

## Signature

The signed bytes are these lines, in this order, each `name=value\n`, UTF-8, absent optionals as empty:

    v, alg, cid, cmd, st, e, ss, sn, ts, bref, bh, pid, fid

`sig` = Ed25519 over those bytes, hex. `alg` is inside the signed bytes, so the scheme cannot be
downgraded without breaking the signature. An unknown or empty `alg` fails verification.

## Key registry

`{topology_ns}:gnode:receipt_pubkeys` is a hash: field = `signer`, value = `<alg>:<public key hex>`. Each
producer publishes its own entry at start (idempotent). A verifier resolves `signer` there, then checks
`sig` over the signed bytes. A receipt whose signer is not in the registry is unverifiable, not valid.

## Retention

Each producer trims the stream with `XTRIM MINID ~ <now − 30 d>` after it writes.

## Conformance

`receipt-vectors.json` (byte-identical in gNode `daemon/tests/`, Geodineum-COMMS `tests/` and gNode-Client
`tests/`) holds signed receipts with their expected bytes and signatures.
Every producer asserts against it. A change to the signed format changes the vectors, in every copy, in
one commit.
