# Flutter development

The shared Home Manager environment provides stable Flutter, its bundled Dart SDK and DevTools on production and bootstrap outputs. It reuses the managed Android SDK, JDK and Chrome. macOS also gets CocoaPods for plugins that need its fallback path.

| Host OS | Build and debug targets |
| --- | --- |
| NixOS, x86_64 | Android, web, Linux desktop |
| macOS, Apple silicon | Android, web, iOS, macOS desktop |

## Check a host after applying its configuration

After the owner applies the normal host configuration, open a new terminal and run:

```sh
command -v flutter dart
flutter --version
dart --version
flutter doctor -v
flutter devices
```

Flutter and Dart should resolve through the Nix user profile and report the same versions. The Flutter wrapper supplies Android SDK, JDK and Chrome defaults even when a GUI application inherits no shell variables. Explicit environment variables can override those defaults. An older `flutter config` selection can also affect discovery; use the paths reported by `flutter doctor -v` to diagnose it.

An optional editor warning does not prevent terminal development. Missing Xcode, a simulator runtime, an Android component or a browser does affect its corresponding target. A successful configuration build does not establish that those applications have been activated, that a device boots, or that a GUI-launched shell finds the tools. Check those on each installed host.

Full Xcode is provisioned by production macOS activation. Apple account authentication, licenses, first-launch work and downloading the needed simulator runtime may need the owner's attention. Bootstrap outputs provide the CLI environment without requiring account authentication. The existing mobile-device configuration supplies Android AVDs on macOS; it does not declare an iOS simulator by default. See [macOS hosts](macos.md) for Xcode provisioning.

## Create and build a sample

Use a writable project directory. On NixOS:

```sh
flutter create --platforms=android,web,linux flutter_sample
cd flutter_sample
flutter analyze
flutter test
flutter build web
flutter build linux --debug
flutter build apk --debug
```

On macOS, create the project with `--platforms=android,web,ios,macos` instead. Run the same analysis, tests, web and APK builds, then:

```sh
flutter build macos --debug
flutter build ios --simulator --debug
```

Add a maintained native plugin such as `shared_preferences` when validating the native toolchain:

```sh
flutter pub add shared_preferences
flutter build apk --debug
flutter build apk --debug
```

The second build checks reuse of writable Pub and Gradle caches. Repeat the native plugin build for macOS and the iOS simulator on a Mac. Signing and deploying release builds to physical Apple devices are separate owner-operated tasks.

## Run and debug from a terminal

Select the exact ID from `flutter devices`:

```sh
flutter run -d <device-id>
```

For desktop targets the ID is `linux` or `macos`; for Chrome it is `chrome`. Keep the command's terminal session open. Press `r` for hot reload, `R` for hot restart and `q` to stop the run. Open the DevTools link printed by Flutter to inspect logs, set breakpoints, step and inspect variables. If needed, start the bundled server with `dart devtools` and connect it to the VM service URL printed by the active run.

DevTools and VM service URLs contain session access tokens. Keep them local and private; do not commit them or paste them into shared reports. A new run gets a new URL.

## SDK versions and writable caches

The SDK and engine artifacts live in the immutable Nix store. Pub, Gradle and project build outputs stay in writable user or project directories. Do not run `flutter upgrade` or try to repair the store with `flutter precache` or `sdkmanager`.

Flutter templates and native plugins can require different Android SDK or NDK versions. The managed pin includes the Flutter template's NDK 28.2.13676358 alongside NDK 29, and Android platform 35 for native plugin builds alongside platforms 36 and 37.0. When Gradle reports a missing component, update `packages/android-sdk-repo.json` through `android-sdk-release`, preserve the existing declared versions, review the generated hashes and rebuild the configuration. See `android-sdk-release --help` for its version flags. The SDK cannot download a missing component into the store during a build.

`packages/flutter.nix` temporarily uses the generated `packages/flutter-release.json` while pinned nixpkgs has an older stable SDK. The selected release includes the fix for [GHSA-frr6-h895-5pxp](https://github.com/dart-lang/sdk/security/advisories/GHSA-frr6-h895-5pxp). It switches to nixpkgs' wrapped stable SDK once its version reaches that pin. Generate replacement metadata with the updater from the exact pinned nixpkgs in a disposable upstream checkout; retain its complete release record and validate the existing patches. Do not run that updater in this repository or the store.

## Verification boundaries

Package installation checks exercise Flutter and bundled Dart. The shared profile check executes the commands reached through each production and bootstrap profile, checks target artifacts and compares the Flutter template's Android requirements with the materialized SDK. Darwin output checks reuse that profile check on a Mac builder.

Repository checks and CI prove packaging and configuration. Disposable sample builds prove only the targets actually built. Device boot, app execution, hot reload, DevTools inspection and tool discovery in GUI-launched sessions need separate runtime evidence on each host. Record unavailable evidence as pending rather than inferring it from a successful flake build.
