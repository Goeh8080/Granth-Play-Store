
## Round 14
- The client hides raw ids ("id-467"): `lib/ai/sanitize.dart` swaps them for the praman name.
- Each reply has 👍 / 👎 / Share / Copy / Card PDF. 👎 asks for an optional reason, then queues the item for POST `/ai/flags` (`lib/services/ai_feedback.dart`), retried on each sync.
- Card PDF renders the reply card to an image and writes a one-page PDF on the device (share or save). Nothing goes to the cloud.
- A floating "Ask Tatv AI" button shows on every screen except AI. Back returns to the screen you came from.
