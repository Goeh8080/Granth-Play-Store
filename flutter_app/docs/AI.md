# तत्त्व AI से पूछे, remote config and analytics (Round 12)

## What it does

The user types a question; the app answers with a short Hindi text that is built **only from the प्रमाण (quotes) in the app's own catalog**, and lists the sources. If the sources do not contain the answer, the answer says so and cites nothing.

## Architecture

```
question ──► Retriever (on the phone) ──► ≤12 candidate प्रमाण
                                              │
                                   POST /ask (JSON) ──► AI Worker ──► model
                                              ◄── { answer, cited[], provider }
```

* `lib/ai/retriever.dart` — searches the synced catalog on the phone (Hindi / Hinglish / other-script synonyms, hidden granths excluded) and returns up to 12 candidates `{id, granth, text …}`.
* `lib/ai/ai_client.dart` — one plain `dart:io` POST. The app holds **no provider key**; the Worker does.
* `lib/ai/chat_controller.dart`, `chat_store.dart` — messages, the typing indicator, retry, history kept in the app's private storage.
* `lib/screens/ai_screen.dart` — the chat UI (themed, all 8 card looks).

## Contract

* Endpoint: `https://granth-ai.vedpuran8090.workers.dev/ask` (`GET /health` for a check). Overridable by `endpoints.ai` in the remote config (https only).
* Header `X-Granth-Client: granth-app-1`.
* Request: `question` (≤500 chars), `history` (last 4 turns, each ≤600 chars), `candidates` (≤12).
* Reply: `answer`, `cited` (ids, always a subset of the candidates), `provider`.
* Errors: 400 / 403 / 413 → "rejected / too large" (no retry offered); 429 → rate limited; 503, timeout (45 s), offline → retryable with a Hindi message.
* Answers take about 3–25 s; a typing indicator is shown meanwhile.

## Privacy

The question, the last turns of history and the candidate quotes are sent to the Worker, which forwards them to a model provider. Nothing else (no account, no device id). Chats are stored only on the phone and can be deleted (कानूनी और नीतियाँ → डेटा हटाने का अधिकार → चैट इतिहास मिटाएँ). The Worker's own logging / retention policy is **not verified by the app's authors**: the owner should confirm it before relying on the wording of the privacy page. The AI can be wrong; the screen says so.

## Remote config

* `https://granth-admin.vedpuran8090.workers.dev/config.json`, fetched at start and on resume (ETag, cached in `remote_config.json`).
* Signed with Ed25519 (`signature` over the canonical body); the public key is embedded in `lib/config.dart`. Unsigned or badly signed files are ignored.
* Applied only if: signature valid, `schema` = 1, `version` ≥ cached, `min_app` ≤ build number, structure parseable. Otherwise the last good config (or the bundled one) stays and nothing is shown to the user.
* Fields the app reads: `hidden` (granth ids), `announcement`, `banner`, `flags.ai`, `flags.analytics`, `analytics.sample`, `endpoints.ai`, `structure` (religion / group icons and tones), `contacts_page` (title + contacts). Unknown fields are ignored.
* Unknown icon names fall back to the neutral icon; the legacy `ektara` icon is drawn as the Kabir symbol.

## Analytics

Anonymous counters, one batch per day at most 5 times, sent to `https://granth-admin.vedpuran8090.workers.dev/events` (gzip JSON, ≤7.5 KB):

`v, batch_id, iid (random install id), app, app_version, build, os, sdk, cfg (config version), day, fg_s, sessions, open{g,f,t,p}, watch_s{g,f,scr}, sync{ok,fail,kinds}, pdf{ok,fail,kinds}, ai{asked,answered,cite_tap}`

Not sent: name, phone, e-mail, device or ad id, location, question or answer text, granth text. Only while the app is in the foreground; off when the config flag says so; sampled by `analytics.sample`. Failed uploads are retried with the same `batch_id` (429 / 5xx / network); 4xx batches are dropped; batches older than 2 days are dropped; at most 20 are queued.

### App key (`X-App-Key`)

Every `POST /events` also carries the **permanent app key** as the HTTP header `X-App-Key`, so the dashboard can split *verified* (genuine app) from *unverified* installs and show installs by app version (`app_version` + `build` are in the body). The key is compiled in at build time: `String.fromEnvironment('APP_KEY')` in `lib/config.dart`, set with `--dart-define=APP_KEY=…` (preferably `--dart-define-from-file=<temp json>` so it is not echoed). It is **never rotated** (every installed app would lose its verified tag), it is an **identifier, not a secret** (a key inside a public APK can be extracted), and its value is **not in the repository** (nor in config.json, logs or crash reports). When `APP_KEY` is empty (tests, forks, CI without the secret) the header is simply left out — the server still stores the batch as "unverified". CI: if a repository secret named `APP_KEY` exists, `.github/workflows/android-apk.yml` passes it to the release builds; without it the workflow works unchanged.

## Tests

`test/ai_*_test.dart`, `test/remote_config_test.dart` (signed fixtures from a throwaway key, see `tool/gen_test_configs.py`; `live_config.json` is a real signed copy), `test/analytics_test.dart`, `test/legal_ui_test.dart`.

## Round 13: ask the admin, admin answers, admin notes, ज्ञान चर्चा

- **Cannot-answer rule** (`lib/ai/cannot_answer.dart`): the AI "cannot answer" when it cited no real source (no catalog praman, admin note or topic), or its text contains a refusal phrase ("उत्तर नहीं मिला", …) and it did not cite an admin note. Errors (offline/429) keep their own retry card.
- Then the chat asks **"क्या आप यह प्रश्न admin को भेजना चाहेंगे?"** (हाँ/नहीं). हाँ → `POST /ai/questions` `{iid, question, lang:"hi"}` with the analytics install id (+ `X-App-Key` when built with one). 5/day per install is also counted on the device. Hindi messages for 202 (sent/duplicate), 429, 400, offline, unavailable.
- **Answers**: `GET /ai/answers?iid=` runs in the ~2 min sync cycle and on start/resume (throttled ~100 s, 429 → ~30 min back-off). Each answer is stored in the chat it was asked from (or a new chat) as role `admin` ("admin का संदेश आया"), deduped by `id@answered_at`; `POST /ai/answers/ack` only after it is saved. A local notification "आपका उत्तर आ गया है" goes through the existing native channel (`answerNotice` → `PdfService`, Android 13 permission asked the same way as for PDFs, after a question is sent). Admin messages are never sent to the AI as history.
- **Knowledge**: `GET /ai/knowledge.json` (ETag + disk copy). The best-matching notes (title = question, text = answer) and catalog topics join the normal `/ask` candidates, ≤12 in total, text ≤500 chars. Ids cannot clash with pramans: notes `1000000000+id`, topics `1500000000+id`. The granth-ai Worker needed no change (it accepts any integer id).
- **ज्ञान चर्चा** (pill in the AI header). Assumptions, kept minimal: it picks a random admin note (else a random praman topic), posts the question in the chat, the user thinks or types their own answer, then "उत्तर और प्रमाण देखें" shows the answer plus the praman citations (the granths that hold them) found by the local retriever. No scoring of the user's answer.
