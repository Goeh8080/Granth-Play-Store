# ग्रंथ प्रबंधन — Android ऐप

यह Expo / React Native का छोटा शेल है। ऐप का पूरा UI वेबसाइट वाला ही है, जो
`android/app/src/main/assets/web/index.html` में एक फ़ाइल के रूप में बंद है
(रिपो की जड़ पर `npm run build:apk` से बनती है)।

## बिल्ड

1. रिपो की जड़ पर: `npm ci && npm run build:apk`
2. यहाँ: `npm ci`
3. `cd android && ./gradlew assembleRelease` — साइनिंग के लिए जड़ की `README.md` देखें।

वर्जन `version.properties` में है (versionName / versionCode)। हर नई Play अपलोड पर
`VERSION_CODE` बढ़ाएँ।

GitHub पर पुश करते ही **Actions → Android APK** वर्कफ़्लो साइन की हुई APK और AAB बनाता है
(Secrets न हों तो debug key से, चेतावनी के साथ)।

विस्तार [ARCHITECTURE.md](ARCHITECTURE.md) में है।
