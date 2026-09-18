# acme.sh -> weir, Stage 1 findings

Porting the crypto/HTTP/JSON heart of acme.sh v3.1.5 to weir (rel45). Scope:
encoding utils, HTTP layer, JWS signed-request envelope. All files `weir check`
clean; all acceptance tests green (`test/`, run via the rel45 binary).

Verdict: **weir replaces the entire HTTP+JSON+base64+digest surface cleanly and
reads dramatically better. openssl remains the fallback for exactly three
things — key parsing, asymmetric signing, and (incidentally) a raw digest of
arbitrary bytes. The JWS envelope, base64url, hex, and RFC-7638 thumbprint are
provably correct (openssl-oracle verified).**

## (a) What replaced bash cleanly

### HTTP: typed `Http.send` vs curl-wrapper text soup — the headline
acme.sh `_get`/`_post` (73+129 = 202 lines) shell out to curl/wget, write
headers to a temp FILE ($HTTP_HEADER), then string-parse it:
`grep -i "Replay-Nonce:" | _head_n 1 | tr -d "\r\n " | cut -d ':' -f 2 | cut -d , -f 1`.
Status: `grep "^HTTP" | _tail_n 1 | cut -d " " -f 2`.
weir `Http.send` returns a typed record (`status:int`, `headers:seq<string*string>`,
`body`). My whole HTTP+directory+nonce layer is **33 lines**. Nonce is a
`match header resp.headers "Replay-Nonce" with Some n / None -> fail`. Proven
LIVE against api.github.com (status 200, typed field read via `from json`, Date
header read back).

### Directory: `from json` into a typed record vs `_egrep_o` per field
acme.sh: `_egrep_o 'newNonce" *: *"[^"]*"' | cut -d '"' -f 3`. weir:
`resp.body |> from json Directory` — nested `meta` as `Option<DirMeta>`.

### base64 / base64url
Native base64 (`Str/Bytes.toBase64`, `Bytes.fromBase64`). base64url = 3-line
transform (`+`->`-`, `/`->`_`, strip `=`), matching `_url_replace` exactly.
Re-pad for decode = a clean `match (len % 4)`.

### Canonical JSON for RFC 7638 — mostly free, one nuance
`to json` is compact (no whitespace) FOR FREE. But it preserves DECLARATION
order, NOT alphabetical ([D:record-order]) — so sorted-key canonicalization is
obtained by declaring JWK fields in sorted order (crv,kty,x,y / e,kty,n).
Zero string-plumbing; acme.sh instead hand-concatenates JSON then `tr -d ' '`.
Thumbprints match openssl byte-for-byte (EC and RSA); pinned EC-JWK KAT green.

### Digest
`Str.sha256`/`Bytes.sha256` cover `_digest sha256` for the thumbprint with no
shell-out.

### LOC (ported functions)
| layer | bash | weir |
|---|---|---|
| encoding (_base64/_dbase64/_url_replace/_durl/_h2b/_hex_dump/_digest) | ~121 | 115 |
| crypto/JWK (_calcjwk 111 + _sign 55) | ~166 | 101 |
| JWS (envelope of _send_signed_request) | ~80 | 36 |
| HTTP (_get 73 + _post 129 + dir/nonce scraping) | ~230 | 33 |
HTTP standout: ~230 bash -> 33 weir, typed end-to-end. Encoding is ~even
because weir lacks hex primitives (below) — most of encoding.weir is a
hand-rolled hex/base64 codec bash delegates to openssl/od/xxd.

## (b) The crypto boundary — what still needs openssl
weir has sha256 but NO HMAC, NO asymmetric signing, NO key parsing, NO X.509.
Stage-1 openssl fallbacks:
1. Key material (rsaJwk/ecJwk): read RSA modulus/exponent, EC public point. I
   use CLEANER openssl than acme.sh — EC point via
   `openssl pkey -pubout -outform DER` tail (04||X||Y) sliced, not acme.sh's
   fragile `grep -n pub: | sed -n "$pubi,$pubj p"` text-parse.
2. Signing (signRs256/signEs): `openssl dgst -sha256 -sign`. RS256 raw ->
   base64url. ES256: openssl emits DER SEQUENCE{r,s}; JWS wants R||S, so parse
   r/s via `openssl asn1parse` (acme.sh's exact way), left-pad, concat.

Shell-out is CLEAN: literal heads, splices for key paths, temp files for the
(non-secret) signing input, `File.readBytes`+`Bytes.toBase64` for the sig bytes,
`| orFail "msg"` as the per-call assert. No `sh -c` needed. Signature returns as
`Bytes` so no `tr -d '\r\n'` newline dance (bash `_base64` has two paths just for
that).

Wanted native member: **HMAC-SHA256** — acme.sh `_hmac` (line 1090) is needed
for External Account Binding (EAB, lines 4289-4298). A `Bytes.hmacSha256 key
msg : Bytes` would remove one fallback (pure deterministic primitive, fits next
to `Bytes.sha256`). Asymmetric sign/verify correctly stays openssl.

## (c) Missing / awkward members (with the acme.sh line)
1. NO hex<->bytes primitive (biggest gap). acme.sh `_h2b`/`_hex_dump`
   everywhere: `$modulus | _h2b | _base64 | _url_replace` (_calcjwk:1844),
   `$_ec_r$_ec_s | _h2b | _base64` (_sign:1163). weir has base64 but no
   `Bytes.fromHex`/`toHex`/`Str.fromHex`. Hand-rolled hexToByteVals + pure
   base64 encoder + bytesToHex (~70 lines) that a `Bytes.fromHex`/`toHex` pair
   erases. Single most valuable member for crypto ports (fingerprint, modulus,
   EC points, HMAC hexkeys are all hex).
2. `Bytes` has no slicing / per-byte access (`b[0..2]` is a type error; no
   `Bytes.sub`/`ofInts`). EC point split (X=bytes 1..32, Y=33..64) forced me
   into the hex-STRING domain to slice. `Bytes.sub start len` would fix it.
3. No `Str.replicate`/left-pad. EC r/s pad
   (`while [ ${#_ec_r} -lt 64 ]; do _ec_r=0$_ec_r; done`, _sign:1138) needed
   `Seq.replicate n "0" |> Seq.fold (+) ""`.
4. `Str.trimEnd` takes no char-set (whitespace only). Stripping base64 `=` used
   `Str.replace "=" ""` — safe only because `=` is trailing-pad-only. A
   `Str.trimEnd chars` (bash `tr -d '='`) would be safer/clearer.
5. A command-backed binding piped into a LOCAL function re-enters command mode:
   `ints |> Seq.item 0 |> pad` (ints from an openssl pipeline, pad a local let)
   errors `'|>' applies functions; feed a program with '|'`. Prefix form
   `pad (Seq.item 0 ints)` compiles. Error points at `|>`, not the cause.
6. `from json Acme.Directory` (qualified imported type in the adapter slot)
   parse-errors; bare works inside the module (used a `parseDirectory` wrapper).
7. Header pairs not a map (correct — dup headers legal), but every ACME port
   re-writes a case-insensitive `Seq.tryPick` lookup. A `Http.header resp name`
   convenience would help given Replay-Nonce/Location/Retry-After centrality.

Non-issues (all caught by check or a failing assert, none silent): `==` not `=`,
`<>` not `!=`; range arithmetic endpoints need parens `[0..((n/2)-1)]`;
value-head stdin pipes append a newline (corrupted an openssl digest oracle
until I used `File.writeBytes (Str.toUtf8 x)` — byte-exact).

## (d) Stage-2+ estimate
Stage 1 proved envelope + transport + encodings correct. Remaining for issuance:
1. Account reg (_regAccount): POST new-account JWS, capture Location as kid,
   switch protected jwk->kid. SMALL (envelope+header lookup exist). + EAB (needs
   HMAC gap).
2. Nonce lifecycle+retry: acme.sh's 20-try backoff `while` loop maps onto weir
   `retry attempts=N delay=D` cleanly. SMALL-MEDIUM, reads better.
3. Order+authz+challenge: POST newOrder, parse order, GET authz, key
   authorization = token + "." + thumbprint (DONE), write http-01 or dns TXT
   (`_digest sha256 | _url_replace` — encoding DONE), POST challenge, poll authz
   valid (weir `poll`). MEDIUM — many typed JSON shapes, crypto done.
4. CSR+finalize+download: openssl CSR (clean fallback), base64url DER, POST
   finalize, poll valid, GET cert. MEDIUM, mostly openssl plumbing + same
   POST-and-parse pattern.
5. Lifecycle: expiry via `Instant.parseWith` (native, nice), renewal, revoke
   (signed POST). SMALL-MEDIUM; Instant/Duration cover date math natively.

Overall: entirely feasible in weir. Only anticipated new gaps are HMAC (EAB) and
the hex/Bytes-slicing members already flagged — additive primitives, not
paradigm problems. The POST-signed-request-parse-typed-JSON pattern is the whole
protocol's spine and it is clean. CSR/key/cert parsing stay in openssl — exactly
what a shell language should delegate, with good shell-out ergonomics.
