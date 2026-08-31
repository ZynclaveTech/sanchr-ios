# Audit triage — 2026-08-31

`Scripts/check_unread_state.py --audit` finds product functions whose only
callers are tests. The first run produced 58 findings. This is what they were.

## Protocol requirements — 49, all false positives

A protocol requirement is called *through* the protocol, so its implementations
have no direct caller and look exactly like dead code from here. Forty-nine of
the fifty-eight were this, which is enough noise to bury the one real bug.

The audit skips them now, so a future run reports the nine below rather than
fifty-eight. That is why this check gates nothing and only runs on request:
it cannot tell a conformance from a corpse without help, and it now has help.

## Real — 1

### Call duration padding is not running

`CallDurationPaddingManager` "computes call duration padding buckets and delays
peer connection teardown until the next bucket boundary, hiding real call
duration from the server". It is constructed in `CallManager`, it has tests,
and the only method anyone calls on it is `cancel()`.

`paddingEnd` and `padThenComplete` — the whole of it — are never invoked, so
the server sees exact call durations.

Not fixed here: switching it on holds the peer connection open to the next
bucket boundary, so a ten-second call keeps a connection alive for a minute and
an hour-long call for the rest of the hour. That is a real cost in battery and
in held connections, and which way it should go is a product decision rather
than a bug fix.

## Unused, and harmless — 8

- `seedRecents`, `startForTesting`, `stageCapturedMediaForTesting` — test seams,
  named as such. The last two say so in the name, which is at least honest.
- `usersWithPendingIdentityChanges` — the per-user `hasPendingIdentityChange`
  is what the chat banner uses and it works; this set-returning form would suit
  a list-level indicator that does not exist.
- `cachedPresence` — an accessor over a cache nothing reads through.
- `contactFallbackText`, `locationFallbackText` — contacts and locations are
  sent as structured content now, so nothing produces the text form. The
  *parser* is still used, for messages from older clients, and these two are
  the tested statement of the format it must accept. Worth keeping for that
  reason alone.

---

# Media upload dedup on forward — checked and rejected, 2026-08-31

Forwarding one file to several conversations uploads it several times. That
was raised as waste worth fixing. It is not waste.

`MediaUploadManager` derives the key as the paper's Defense 2 specifies:

    MediaK_n = HKDF(CK_n, file_hash, "media-v1")

`CK_n` is *that conversation's* media chain key, and it is erased on the next
line. One ciphertext has one key, so an upload reused elsewhere would belong to
a conversation whose media key was never derived from its own chain. Deriving
it properly means re-encrypting, which means re-uploading.

It would also break the paper's Cross-Domain Persistence Invariant: MediaK is
cross-domain but not persistent, because the chain advances past it. Shared
across conversations it would live until the slowest chain advanced — both
cross-domain and persistent, the pair the design exists to keep apart — and
compromising one conversation would expose media delivered in another.

Compression is not key-derived, so that part *is* shared
(`MessageSender.PreparedVideo`, #88). Encryption and upload are not.

Note for anyone re-opening this: the first argument given against dedup was
metadata — one media id visible in several conversations. That argument is
weak, and the paper explicitly puts ciphertext correlation out of scope. The
cryptographic argument above is the one that holds.
