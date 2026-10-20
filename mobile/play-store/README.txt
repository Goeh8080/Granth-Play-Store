Play Console listing notes for ग्रंथ प्रबंधन
Package: com.wnm.granthprabandhan
Version name / code: see ../version.properties (1.0.2 / 22)

Signing
- Release builds from this repo are signed with the key configured in the
  GRANTH_KEYSTORE_* variables (CI: ANDROID_KEYSTORE_* secrets).
- The new "granth-release" key (SHA-256 01:F2:87:C6:02:C0:72:A5:CB:B3:F7:FF:23:37:62:1C:32:CA:AD:D4:6D:78:C4:79:3E:B1:22:FF:5D:9D:89:86)
  is NOT the earlier Play upload key "satlok"
  (SHA-256 68:C7:CF:34:EC:F0:FA:DA:21:05:C2:65:D2:59:54:96:BA:A1:BB:C9:7C:3F:DD:BC:35:D2:1D:BE:8D:0E:DD:DE).
  To upload to Play either put the satlok keystore into the CI secrets, or request an
  upload-key reset in Play Console (App integrity) and register granth-release.
- An app installed from an APK signed with a different key must be uninstalled
  before a build signed with granth-release can be installed.

Phone screenshots are 1080x1920 (9:16), taken from the phone, in screenshots/ and granth-prabandhan-screenshots.zip.
