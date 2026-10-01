# YTMusicUltimate
<p align="center">
<img src=https://user-images.githubusercontent.com/38832025/235781424-06d81647-b3db-4d9b-94dc-cd65cdf09145.png?raw=true) />
</p>    

<p align="center">
<img src=https://user-images.githubusercontent.com/38832025/235781207-6d1ad44e-0c32-4aec-9c75-cb928ca8a0d3.png?raw=true) />
</p>

<p align="center">
The best tweak for the YouTube Music on iOS.
</p>

## Download Links

* **Jailbreak:**
Add __[https://ginsu.dev/repo](https://ginsu.dev/repo)__ to your favorite installer and download latest version from there, or from __[Releases](https://github.com/ginsudev/YTMusicUltimate/releases)__ page.

(arm.deb version for Rootful and arm64.deb version for Rootless devices)

* **Sideloading:**
  We no longer provide a sideloading IPA but you can build one yourself, keep reading:

## How to build a YTMusicUltimate IPA by yourself using Github actions

If this is your first time here, start from step 1. If you built a YTMU IPA before, skip steps 1 and 2. Instead, click on the "Sync fork" button to get the latest version of the tweak and continue through step 3.

1. Fork this repository using the fork button on the top right.
2. On your forked repository, go to Repository Settings > Actions, enable Read and Write permissions.
3. Go to the Actions tab on your forked repo, click on "Build and Release YTMusicUltimate" located on the left side. Click "Run workflow" button located on the right side.
4. Find a decrypted YTMusic .ipa file (we cannot provide you this due to legal reasons) and upload it to a file provider(filebin.net or Dropbox is recommended). Paste the url to the necessary field and click "Run workflow".
5. Wait for the build to finish. You can download the tweaked IPA from the releases section of your forked repo. (If you can't find the releases section, go to your forked repo and add /releases to the url. i.e github.com/user/YTMusicUltimate/releases)

## IPA building troubleshooting(I can't build the IPA/Github action fails/I can't find the releases section etc.)

99.9% of the time, the culprit is the IPA URL you provided. You HAVE TO provide a decryped IPA. It cannot be any other extension, it has to be a **.ipa** file. Find a decrypted YTMusic IPA(we can't help you with that), upload it to filebin.net or Dropbox, give the direct link to the GitHub action. If you find a working ipa and upload it properly, everything will start working perfectly, pinky promise.

If the github action works and you cannot find where you can download the result, you need to add /releases to the url of your forked repository. It'll probably look like this: https://github.com/YOURUSERNAME/YTMusicUltimate/releases, don't forget to replace the YOURUSERNAME part with your username. It may seem invisible but if the github action is successful, IPA will be there.


## How to build the package by yourself on your device
1. Install __[Theos](https://theos.dev/docs/installation)__
2. Clone this repo __[using git](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository)__
3. Cd your YTMusicUltimate folder and run:

   • '**make clean package**' to build deb for rootful device
   
   • '**make clean package ROOTLESS=1**' to build deb for rootless device
   
   • '**make clean package SIDELOADING=1**' to build deb for injecting in to ipa
   
   

   • To learn how to inject tweaks in to ipa visit __[here (Azule)](https://github.com/Al4ise/Azule)__




Made with ❤ by Ginsu and Dayanch96

### Save to Server (V3)

Uploads use `https://radio.subasically.me/api/upload`; library checks use
`https://radio.subasically.me/api/tracks/exists`. Saved endpoint overrides for the
retired V2 host at those paths migrate automatically. Other custom overrides are
preserved and must use HTTPS.

In **YTMusicUltimate → Player Settings → Save to Server → Server API key**, tap
**Paste and Save** after copying the V3 API key. The tweak never displays the value
or stores it in preferences: it uses the signed app's default Keychain access group,
with storage restricted to this unlocked iPhone. The row shows only whether it is
configured. A different signing identity/access group may require re-entry.
Choose **Bosnian** (`bs`, the default) or **English** (`en`) for the song before
using **Save to Server**. No language detection is performed.

For a local build on a Mac with Theos, gmake, cyan, and Xcode already installed:

```sh
THEOS=/path/to/theos gmake package DEBUG=0 FINALPACKAGE=1 SIDELOADING=1
# Copy your decrypted input IPA to input.ipa first; keep the reference untouched.
cyan -i ./input.ipa -o ./YTMusicUltimate-v3.ipa -uwsf ./packages/com.ginsu.ytmusicultimate_2.4.1_iphoneos-arm.deb -n 'YouTube Music' -b com.google.ios.youtubemusic
python3 scripts/regression_checks.py --ipa ./YTMusicUltimate-v3.ipa
```

The regression command runs offline Foundation tests of the actual multipart and
upload-response helpers, then checks the IPA's secure defaults and original bundle
ID. It preserves the source app's unrelated ATS exceptions. Cyan fake-signing is
only assembly preparation; a signing tool must provision the app for the phone.

To sideload with Sideloadly, select the built IPA, the iPhone, and the same Apple
signing account and effective installed bundle ID as the existing installation.
Perform an overwrite update to preserve app data; complete private signing/2FA
prompts yourself. Unlock/trust the phone and enable Developer Mode or trust the
signed developer if iOS requests it. After installation, paste the V3 API key in
the setting above and verify a new upload, duplicate feedback, actionable errors,
and the green library refresh. Relaunch and verify Keychain persistence; verify it
again after an update signed with the same identity. Check the signing profile's
expiration and refresh before expiry. Device signing, installation, and live server
acceptance are separate from the local build checks.
