/// App-wide constants that the owner may need to change. Nothing secret lives here: the AI
/// Worker URL is public by design (the Worker holds the provider keys, the app never does).
library;

/// The AI Worker (Cloudflare Workers). `POST {kAiEndpoint}/ask`, `GET {kAiEndpoint}/health`.
/// Override at build time: `flutter build apk --dart-define=AI_ENDPOINT=https://…`.
const String kAiEndpoint = String.fromEnvironment('AI_ENDPOINT', defaultValue: 'https://granth-ai.vedpuran8090.workers.dev');

/// Sent as `X-Granth-Client` on every AI request (the Worker rejects requests without it).
const String kAiClientHeader = 'granth-app-1';

/// The address for complaints, takedown requests and data requests (शिकायत और संपर्क page).
/// TODO(owner): put the real contact e-mail here. It is empty on purpose — the app does NOT
/// invent an address; while it is empty the legal pages say "संपर्क ईमेल जल्द जोड़ा जाएगा".
/// Can also be set at build time: `--dart-define=CONTACT_EMAIL=name@example.com`.
const String kContactEmail = String.fromEnvironment('CONTACT_EMAIL', defaultValue: '');

/// The date every legal page was last updated (shown on each page).
const String kLegalUpdated = '25 अक्टूबर 2026';

/// App version shown on the About page (keep equal to pubspec.yaml; the About page also shows the
/// version read from the installed package when it is available).
const String kAppVersion = '1.0.0';

/// The app's build number (the `+1` of 1.0.0+1). The remote config's `min_app` is compared to it.
const int kBuildNumber = 1;

/// Same as pubspec.yaml's `version:` — sent with analytics batches.
const String kAppFull = '1.0.0+1';

/// The admin server (public config + anonymous usage counts). See docs/AI.md / docs/REMOTE.md.
const String kConfigUrl = String.fromEnvironment('CONFIG_URL', defaultValue: 'https://granth-admin.vedpuran8090.workers.dev/config.json');
const String kEventsUrl = String.fromEnvironment('EVENTS_URL', defaultValue: 'https://granth-admin.vedpuran8090.workers.dev/events');

/// The permanent app key: an *identifier*, not a secret (it only tags genuine-app traffic so the
/// admin dashboard can split verified / unverified installs). It is never kept in the repository:
/// it is compiled in at build time with `--dart-define=APP_KEY=…` (or `--dart-define-from-file`).
/// Empty (CI, tests, forks) = the `X-App-Key` header is simply left out. Never rotated.
const String kAppKey = String.fromEnvironment('APP_KEY', defaultValue: '');

/// Public key (raw Ed25519, base64) that signs the remote config. Not a secret.
const String kConfigPublicKey = 'kdPKX/LfjdbPxugpPnpeEejTZlXKzrcoOg88IK83Fb4=';
