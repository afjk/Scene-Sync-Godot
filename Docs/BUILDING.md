# Scene Sync Godot Build手順

この文書は、別PCでcloneからAndroid Debug APKを再現し、Meta Quest 3、PICO 4 Ultra、VIVE Focus Vision、Android XR端末へインストールするための手順です。release APK／AABの作成、署名鍵、ストア提出は対象外です。

## 固定version

| 項目 | Version／設定 |
| --- | --- |
| Godot | `.NET 4.7.2-stable` |
| C# target framework | `net8.0` |
| 開発用.NET SDK | `9.0`以上 |
| Godot Android export templates | `4.7.2-stable`のMono templates |
| Godot OpenXR Vendors | `5.1.0-stable` |
| Scene Sync addon | `0.5.1` |
| Scene Sync Rapier tag | `scenesync-v0.8.28-r0.30.0.3` |
| Rapier core | `0.30.0` deterministic |
| godot-gsplat | commit `dfc8df4893f0f6e26c847590ff1669fa8404da6d` |
| cargo-ndk | `4.1.2` |
| Linux build container | `rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f` |
| OpenJDK | `17` |
| Android compile SDK Platform | `36`（export targetは`35`） |
| Android SDK Build-Tools | `36.1.0` |
| CMake | `3.10.2.4988404` |
| Android NDK（Godot template） | `29.0.14206865` |
| Android NDK（godot-gsplat再build） | `28.1.13356709` |
| ABI | `arm64-v8a` |
| Package | `com.afjk.scenesyncgodot` |

MR基盤は`afjk/MR-Godot-Template`のcommit `5d21cf1c7dcd7c1995dff28d02021eb412eda606`、Scene Sync addon `0.5.1`とそのRapier runtimeは`afjk/afjk.jp`のcommit `3385e633c1710feb11636ad278ad106fe490ade5`に固定されています。SDKの詳細と更新方法は[SCENE_SYNC_SDK.md](SCENE_SYNC_SDK.md)を参照してください。

Gaussian Splatの実rendererは`shiena/godot-gsplat`の固定commitからbuildし、macOS arm64とAndroid arm64のnative libraryをrepositoryにvendorしています。Android binaryはgodot-gsplat再build用NDK、固定Cargo.lock、Scene Syncのpush-constant compatibility patchを使用します。

## 1. Repositoryを取得する

```bash
git clone https://github.com/afjk/Scene-Sync-Godot.git
cd Scene-Sync-Godot
```

clone後に`addons/scene_sync`、`addons/godot-rapier3d`、`addons/godot_gsplat`、`godot_gsplat.gdextension`が存在することを確認します。通常のbuildでSDKやnative libraryをネットワークから取得し直す必要はありません。

## 2. 開発ツールを導入する

### .NET SDK 9以上

`.csproj`のtarget frameworkは`net8.0`ですが、開発環境とCIには.NET SDK 9以上を使用します。

```bash
dotnet --version
dotnet --list-sdks
```

### OpenJDK 17

TemurinなどのOpenJDK 17を導入します。

```bash
java -version
```

複数のJDKがある場合、Godotの`Editor Settings > Export > Android > Java SDK Path`にはJDK 17のroot directoryを指定します。

### Android SDK

Android StudioまたはAndroid command-line toolsを導入し、CIと同じpackageをインストールします。`<ANDROID_SDK_ROOT>`は実際のAndroid SDK directoryへ置き換えてください。

```bash
<ANDROID_SDK_ROOT>/cmdline-tools/latest/bin/sdkmanager \
  --sdk_root=<ANDROID_SDK_ROOT> \
  "platform-tools" \
  "build-tools;36.1.0" \
  "platforms;android-36" \
  "cmake;3.10.2.4988404" \
  "ndk;29.0.14206865" \
  "ndk;28.1.13356709"
```

Godotの`Editor Settings > Export > Android > Android SDK Path`に同じSDK directoryを指定します。directory直下の`platform-tools/adb`が実行できることを確認してください。

### Godot .NET 4.7.2-stable

[Godot 4.7.2-stable release](https://github.com/godotengine/godot/releases/tag/4.7.2-stable)から、OSに合う`.NET`／`mono`版editorを取得します。標準版GodotではC#をbuildできません。

Godot本体に加え、同じreleaseの`mono_export_templates`を取得し、Godotの`Manage Export Templates`から導入します。標準版export templatesではなく、Mono版である必要があります。インストール後、`4.7.2.stable.mono`のtemplate directoryに`android_debug.apk`と`android_source.zip`があることを確認します。

以降では.NET版Godot実行ファイルを`GODOT_BIN`へ設定します。例:

```bash
# macOSの例
GODOT_BIN="/Applications/Godot_mono.app/Contents/MacOS/Godot"

# Linuxでrelease archiveを展開した場合の例
# GODOT_BIN="/path/to/Godot_v4.7.2-stable_mono_linux_x86_64"

"$GODOT_BIN" --version
```

version出力が`4.7.2.stable.mono`で始まることを確認してください。

### OpenXR Vendors 5.1.0-stable

[Godot OpenXR Vendors 5.1.0-stable](https://github.com/GodotVR/godot_openxr_vendors/releases/tag/5.1.0-stable)の`godotopenxrvendorsaddon.zip`を取得します。ZIP内の次のdirectoryをprojectへ配置します。

```text
asset/addons/godotopenxrvendors
  -> addons/godotopenxrvendors
```

次のファイルが存在すれば配置できています。

```bash
test -f addons/godotopenxrvendors/plugin.gdextension
```

このaddonはdownload可能な依存物でありrepositoryには含まれません。CIも固定versionを毎回配置します。

### Scene Sync Rapier GDExtension

`addons/godot-rapier3d`はScene Sync SDKと同じupstream commitから完全vendorされています。別のRapier buildやAsset Library版で上書きしないでください。固定releaseのprovenanceとplatform matrixは次で確認できます。

```bash
cat addons/godot-rapier3d/SCENESYNC_BUILD.txt
test -f addons/godot-rapier3d/bin/libgodot_rapier.android.aarch64-linux-android.so
```

同梱targetはmacOS universal、Android arm64、Linux x86_64、Windows x86_64です。対応native libraryがないplatformではScene Syncのphysics metadata同期は動作しますが、Rapier simulationは無効になります。

### Gaussian Splat GDExtension

`godot-gsplat`は`addons/godot_gsplat`へvendorし、rootの`godot_gsplat.gdextension`からnative libraryを解決します。本リポジトリに含むtargetはLinux x86_64、macOS arm64、Android arm64です。

```bash
cat addons/godot_gsplat/SCENESYNC_BUILD.txt
test -f godot_gsplat.gdextension
test -f addons/godot_gsplat/bin/android-arm64/libgodot_gsplat.so
file addons/godot_gsplat/bin/android-arm64/libgodot_gsplat.so
```

Android binaryを再buildする場合はRust `1.94.0`、`cargo-ndk 4.1.2`、NDK `28.1.13356709`を用意し、固定スクリプトを実行します。既定binaryを直接上書きせず、まず`build/native`へ出力してSHA-256とAArch64 ELFを比較してください。

```bash
cargo install cargo-ndk --version 4.1.2 --locked
scripts/build_godot_gsplat_android.sh \
  --ndk <ANDROID_SDK_ROOT>/ndk/28.1.13356709
```

Linux x86_64 binaryは固定digestのRust `1.94.0` containerを使用して再buildできます。

```bash
scripts/build_godot_gsplat_linux.sh
```

SceneSync Webは`.ply`、`.sog`、`.spz`などを`KHR_gaussian_splatting` GLBへ正規化します。Godot側はこのGLBを受信し、native rendererで描画します。元のPLYをGodot SDKへ直接渡す経路はありません。

## 3. .NETをrestore・buildする

Repository rootでCIと同じ順序で実行します。`SceneSyncGodot.sln`はGodot C# Android exportがprojectを解決するために必要なので、`.csproj`だけを直接buildせずsolutionを入口にします。

```bash
dotnet restore SceneSyncGodot.sln
dotnet build SceneSyncGodot.sln --configuration Debug --no-restore
```

成功時は`.godot/mono/temp/bin/Debug/SceneSyncGodot.dll`が生成されます。最小C# smoke nodeに加え、vendor済みのScene Sync Loomlet runtimeも同じassemblyへcompileされます。

## 4. Godot importを完了する

```bash
"$GODOT_BIN" --headless --path . --import
```

GDScript parse error、C# assembly load error、OpenXR Vendors plugin load errorがないことを確認します。初回import完了前にexportへ進まないでください。

Rapier対応platformではimport logにnative library load errorがなく、`SceneSyncRapierWorld3D`がClassDBへ登録される必要があります。登録されない場合、Scene Syncは安全にmetadata-onlyへfallbackしますが、deterministic physicsは実行されません。

Linux x86_64、macOS arm64、Android arm64では`GaussianSplatNode3D`もClassDBへ登録される必要があります。Scene SyncがGaussian Splatを読み込んだ際、`Gaussian Splat backend registered: godot-gsplat`が出力されることを確認します。`showing point-cloud preview`はnative backendを使用していないことを示します。

## 5. Android Build TemplateとDebug APKを作る

各export commandの`--install-android-build-template`が、インストール済みMono export templatesの`android_source.zip`からproject用Android Build Templateを準備します。Godot editorでは`Project > Install Android Build Template...`から同じ操作を行えます。

### Meta Quest 3

```bash
mkdir -p build
"$GODOT_BIN" --headless --path . \
  --install-android-build-template \
  --export-debug "Meta Quest 3 Debug" \
  build/scene-sync-godot-quest3-debug.apk
```

### PICO 4 Ultra

```bash
mkdir -p build
"$GODOT_BIN" --headless --path . \
  --install-android-build-template \
  --export-debug "PICO 4 Ultra Debug" \
  build/scene-sync-godot-pico4-ultra-debug.apk
```

### VIVE Focus Vision

```bash
mkdir -p build
"$GODOT_BIN" --headless --path . \
  --install-android-build-template \
  --export-debug "VIVE Focus Vision Debug" \
  build/scene-sync-godot-vive-focus-vision-debug.apk
```

### Android XR

```bash
mkdir -p build
"$GODOT_BIN" --headless --path . \
  --install-android-build-template \
  --export-debug "Android XR Debug" \
  build/scene-sync-godot-android-xr-debug.apk
```

`Android XR Debug` presetは`afjk/MR-Godot-Template`から取り込んだもので、Meta／PICO／Khronos loaderをすべて無効にし、Android XR loaderだけを有効にします。Android XRのpassthroughは標準OpenXRのAlpha environment blendで動作するため、ベンダー固有の追加設定はありません。Scene Sync側でこのpresetの実機確認は行っていません。

すべてDebug APKです。debug keystoreはGodot／Android build環境の標準Debug署名を使用し、release keyやcredentialは不要です。

Android export後、APKに固定Rapierとgodot-gsplatのarm64 libraryが含まれることを確認できます。

```bash
unzip -l build/scene-sync-godot-quest3-debug.apk \
  | grep 'lib/arm64-v8a/libgodot_rapier.android.aarch64-linux-android.so'
unzip -l build/scene-sync-godot-quest3-debug.apk \
  | grep 'lib/arm64-v8a/libgodot_gsplat.so'
```

## 6. ADBでinstall・起動する

対象端末でDeveloper ModeとUSB debuggingを有効にし、USB接続を端末内で許可します。

```bash
<ANDROID_SDK_ROOT>/platform-tools/adb devices
```

端末が`device`として表示されたら、対象APKをinstallします。

```bash
# Quest 3
<ANDROID_SDK_ROOT>/platform-tools/adb install -r \
  build/scene-sync-godot-quest3-debug.apk

# PICO 4 Ultra
<ANDROID_SDK_ROOT>/platform-tools/adb install -r \
  build/scene-sync-godot-pico4-ultra-debug.apk

# VIVE Focus Vision
<ANDROID_SDK_ROOT>/platform-tools/adb install -r \
  build/scene-sync-godot-vive-focus-vision-debug.apk

# Android XR
<ANDROID_SDK_ROOT>/platform-tools/adb install -r \
  build/scene-sync-godot-android-xr-debug.apk
```

packageは4 preset共通で`com.afjk.scenesyncgodot`です。コマンドから起動する場合は次を使用できます。

```bash
<ANDROID_SDK_ROOT>/platform-tools/adb shell monkey \
  -p com.afjk.scenesyncgodot \
  -c android.intent.category.LAUNCHER 1
```

署名が異なる既存APKにより`INSTALL_FAILED_UPDATE_INCOMPATIBLE`になる場合は、端末上の既存アプリを削除してから再installします。`adb uninstall com.afjk.scenesyncgodot`はアプリ内データも削除するため注意してください。

## 7. 端末別の確認点

### Meta Quest 3

- `Meta Quest 3 Debug` presetはMeta OpenXR loader、passthrough required、Hand Tracking optionalを使用します。
- Quest側でpassthrough、Hand Tracking、アプリ権限を有効にします。
- Touch Controllerのaim ray、grip位置の球、controllerから光学式Hand Trackingへ切り替えた際の表示を確認します。
- Godot logで`GaussianSplatNode3D`の登録と`godot-gsplat` backendの選択を確認します。
- Gaussianが単なる色付きpointではなく楕円kernelとopacityで描画され、左右眼で破綻しないことを確認します。
- XR profileのhead-center sorting、center depth、adaptive budgetでフレーム時間と白いちらつきを確認します。

### PICO 4 Ultra

- `PICO 4 Ultra Debug` presetはPICO OpenXR loaderを使用し、Meta loaderは無効です。
- PICO OSを更新し、Developer Mode、USB debugging、Video See-Through、Hand Trackingを有効にします。
- `/interaction_profiles/bytedance/pico4_controller`のaim／grip trackingを確認します。

### VIVE Focus Vision

- `VIVE Focus Vision Debug` presetはKhronos loaderのHTC modeを使用し、Meta／PICO loaderは無効です。
- OpenXR Vendors 5.1.0-stableではHTC Hand TrackingがAndroid manifest上でrequiredになります。
- passthroughは`XR_HTC_passthrough`のplanar layerを使用します。projected passthroughやcamera image取得は対象外です。

### Android XR

- `Android XR Debug` presetはAndroid XR loaderを使用し、Meta／PICO／Khronos loaderは無効です。
- passthroughは標準OpenXRのAlpha environment blendで動作し、ベンダー固有のpassthrough設定はありません。
- MR基盤側でもAndroid XR実機での確認は行われていません。

Quest 3では旧Compatibility構成でGaussian Splatがpoint-preview fallbackとして表示されるところまで確認済みです。Vulkan Mobileとnative rendererを使う実Gaussian描画、per-eye/stereoの見え、passthroughとの併用、性能は未検証です。PICO 4 Ultra、VIVE Focus Vision、Android XRも実機検証が未完了です。端末別項目は確認すべき受け入れ項目であり、動作済みという意味ではありません。

## 8. Scene Sync接続を確認する

1. headsetアプリを起動します。
2. `XROrigin3D`配下の小型composition-layer panelで、右controllerのaim rayとtriggerを使い`Room`と端末を識別できる`Nickname`を入力します。
3. `Connect`を選択します。接続後、panelが縮小することを確認します。
4. PCまたはスマートフォンで `https://afjk.jp/scenesync/?room=<room>` を開きます。
5. Web viewerとheadset双方にparticipantが表示されることを確認します。
6. Web／Unity側からprimitiveを追加し、headsetの`SceneSyncRoot`以下へ同じ位置・回転・scaleで生成されることを確認します。
7. transform変更、削除、後参加時の`scene-state`復元を確認します。
8. GLB objectとLoomlet graphはprimitive同期の成立後に確認します。
9. Physics付きobjectとscene physicsを送信し、`SceneSyncRapierWorld3D`がfixed tickを進め、対応client間でcanonical hashが一致することを確認します。
10. headsetをpause／resumeし、pause中にreconnect loopが発生せず、resume後に安全に再接続できることを確認します。

`SceneSyncRoot`はXR rig外にあり、`XROrigin3D`、camera、hands、controllers、aim rayは同期対象に含まれません。

## 9. Pull Requestのartifact

`main`向けPull Requestまたは`workflow_dispatch`で、`.github/workflows/build-android-xr.yml`が上記と同じ固定versionを使って4 presetをbuildします。

| Preset | Artifact | APK |
| --- | --- | --- |
| `Meta Quest 3 Debug` | `scene-sync-godot-quest3-debug` | `scene-sync-godot-quest3-debug.apk` |
| `PICO 4 Ultra Debug` | `scene-sync-godot-pico4-ultra-debug` | `scene-sync-godot-pico4-ultra-debug.apk` |
| `VIVE Focus Vision Debug` | `scene-sync-godot-vive-focus-vision-debug` | `scene-sync-godot-vive-focus-vision-debug.apk` |
| `Android XR Debug` | `scene-sync-godot-android-xr-debug` | `scene-sync-godot-android-xr-debug.apk` |

artifactの保存期間は14日です。このworkflowはDebug APK専用です。

`.github/workflows/static-checks.yml`は、追跡中の`.gd`のうち`addons/`以外へ`gdformat --diff`と`gdlint`を実行します。vendorしている`addons/scene_sync`、`addons/godot-rapier3d`、`addons/godot_gsplat`は対象外です。ローカルでは`pip install 'gdtoolkit==4.*'`のうえ`gdformat --diff scripts/`と`gdlint scripts/`で同じ確認ができます。

## 10. トラブルシューティング

### `Godot.NET.Sdk`をrestoreできない

- `dotnet --list-sdks`に9.0以上が表示されることを確認します。
- NuGetへ接続できることを確認します。脆弱性情報だけ取得できない`NU1900`はbuildを妨げない場合がありますが、package本体を取得できない場合はrestoreに失敗します。
- `SceneSyncGodot.csproj`のSDK versionを勝手に`latest`へ変更しないでください。

### C# buildは通るがGodotでassemblyをloadできない

- 標準版ではなくGodot `.NET 4.7.2-stable`を使用します。
- `dotnet build`後にGodotの`--import`を実行します。
- Godot本体、Mono export templates、`Godot.NET.Sdk`のversionが`4.7.2`で揃っていることを確認します。

### `No export template found`／Android template error

- `4.7.2-stable`のMono export templatesを導入します。標準版templatesや異なるpatch versionは使用しません。
- `android_debug.apk`と`android_source.zip`が同じtemplate directoryにあることを確認します。
- `--install-android-build-template`を付けるか、Godot editorからAndroid Build Templateを導入します。

### JDK／Android SDK／Gradle error

- Java SDK PathがJDK 17を指していることを確認します。
- Android SDK Pathと`<ANDROID_SDK_ROOT>`が同じdirectoryを指していることを確認します。
- compile SDK Platform 36、target SDK 35、Build-Tools 36.1.0、CMake 3.10.2.4988404、Godot template用NDK 29.0.14206865を再確認します。godot-gsplatを再buildする場合だけ、別途NDK 28.1.13356709も必要です。
- 初回Gradle buildには依存物を取得するネットワーク接続が必要です。

### OpenXR Vendorsのexport項目がない

- `addons/godotopenxrvendors/plugin.gdextension`の存在を確認します。
- OpenXR Vendorsが`5.1.0-stable`であることを確認し、配置後にGodotを再起動または再importします。
- presetごとにMeta、PICO、Khronosのうち対象loaderだけが有効であることを確認します。

### APKは起動するがpassthrough／trackingが動かない

- 端末OS／firmwareを更新し、アプリ権限、passthrough、Hand Trackingを端末側で有効にします。
- `adb logcat`でGodotとOpenXR runtimeの初期化errorを確認します。
- 実行中runtimeが必要なpassthrough、Hand Tracking、controller interaction profileを提供していることを確認します。

### PICOでVulkan起動直後にnative crashする

- Godot `.NET 4.7.2-stable`と同versionのMono export templatesを使用します。4.6.xにはPICO runtimeが誤通知する`XR_META_foveation_eye_tracked`を無効化する設定がありません。
- `PICO 4 Ultra Debug` presetのcustom featureが`pico_xr`であることを確認します。このfeature overrideでeye-tracked foveationだけを無効化し、Vulkan Mobileと固定foveationを維持します。
- `xr/openxr/foveation_with_subsampled_images`は`false`のままにします。PICO 4／4 Ultraではsubsampled image foveationを有効にしません。

### Scene Syncが接続できない／詳細errorがpanelに出ない

Scene Sync addon `0.5.1`の公開APIは接続状態、peer、object追加／削除signalに加え、URL asset取得のretry／失敗を`asset_load_diagnostic` signalで通知します。一方、WebSocket接続失敗やsend失敗の詳細を返すpublic error signal／`last_error`は提供していないため、統合UIだけでは接続失敗の詳細原因を表示できない場合があります。

次を確認してください。

- Android presetのInternet permissionが有効であること
- roomとnicknameが意図した値であること
- `wss://afjk.jp/presence`へ端末のネットワークから接続できること
- `adb logcat`またはGodot consoleの`[SceneSync]` warning

URL assetの問題は`asset_load_diagnostic`の`status`、`attempt`、`reason`、`retryDelay`、`willRetry`も確認してください。このdiagnosticはURLやroom credentialを含みません。

詳細errorが必要な場合でも、vendor済み`addons/scene_sync`をこのrepositoryだけで直接改変しないでください。SDK側にerror公開が必要なら`afjk/afjk.jp`で修正し、新しいcommitへpinを更新します。

### Rapier simulationが無効になる

- `addons/godot-rapier3d/SCENESYNC_BUILD.txt`と対象platformのnative libraryが存在することを確認します。
- Godot `4.7.2`を使用します。vendor binaryはGDExtension API `4.6`をtargetにしており、4.7の後方互換性でloadします。
- Godot logのnative library load errorと、Scene Syncの`physics_runtime_diagnostic`／`rapier_availability_changed`を確認します。
- `get_rapier_status()`の`reason`が`rapier-addon-unavailable`ならmetadata-only fallbackです。
- vendor済みbinaryや`scene_sync_rapier_bridge.gd`を直接patchせず、upstream pinを更新します。

### Gaussian Splatが色付き点群として表示される

色付きpointはScene Syncのdependency-free previewです。実Gaussian rendererは回転、スケール、opacityを使って画面上の楕円kernelを描画します。次を確認します。

- `project.godot`のPCとmobileの両方が`mobile`であること
- `addons/godot_gsplat/bin/android-arm64/libgodot_gsplat.so`がAPKの`lib/arm64-v8a/libgodot_gsplat.so`に入っていること
- `GaussianSplatNode3D`がClassDBに登録されていること
- logに`Gaussian Splat backend registered: godot-gsplat`があり、`showing point-cloud preview`がないこと
- Webが元データを`KHR_gaussian_splatting` GLBへ正規化していること。PLYをGodotへ直接渡すことはできません

Questでのper-eye sorting、stereoの見え、passthrough、性能はnative libraryの読み込みとは別の実機受け入れ項目です。`dragon.compressed.ply`のようなSH0の軽量captureでは形状、opacity、sorting、性能を確認できますが、SH1〜SH3の視点依存色は別のfixtureが必要です。

### .NET Android固有のAOT／Loomlet error

Godot C#のAndroid exportはexperimentalです。desktop build成功後にだけAndroidで失敗する場合は、最小C# smoke node、Scene Sync基本通信、Loomlet runtimeの順に切り分けます。vendor済みSDKからC#ファイルを削除して回避せず、SDKの問題は`afjk/afjk.jp`で修正します。
