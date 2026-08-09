# Scene Sync Godot Build手順

この文書は、別PCでcloneからAndroid Debug APKを再現し、Meta Quest 3、PICO 4 Ultra、VIVE Focus Visionへインストールするための手順です。release APK／AABの作成、署名鍵、ストア提出は対象外です。

## 固定version

| 項目 | Version／設定 |
| --- | --- |
| Godot | `.NET 4.6.3-stable` |
| C# target framework | `net8.0` |
| 開発用.NET SDK | `9.0`以上 |
| Godot Android export templates | `4.6.3-stable`のMono templates |
| Godot OpenXR Vendors | `5.1.0-stable` |
| OpenJDK | `17` |
| Android SDK Platform | `35` |
| Android SDK Build-Tools | `35.0.1` |
| CMake | `3.10.2.4988404` |
| Android NDK | `28.1.13356709` |
| ABI | `arm64-v8a` |
| Package | `com.afjk.scenesyncgodot` |

MR基盤は`afjk/MR-Godot-Template`のcommit `af6ac1233a939b2e09510afc0336459e8630288d`、Scene Sync addon `0.2.0`は`afjk/afjk.jp`のcommit `a2fcdb5cce6e73e40704334625f6d616247b3885`に固定されています。SDKの詳細と更新方法は[SCENE_SYNC_SDK.md](SCENE_SYNC_SDK.md)を参照してください。

## 1. Repositoryを取得する

```bash
git clone https://github.com/afjk/Scene-Sync-Godot.git
cd Scene-Sync-Godot
```

clone後に`addons/scene_sync`が存在することを確認します。通常のbuildでSDKをネットワークから取得し直す必要はありません。

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
  "build-tools;35.0.1" \
  "platforms;android-35" \
  "cmake;3.10.2.4988404" \
  "ndk;28.1.13356709"
```

Godotの`Editor Settings > Export > Android > Android SDK Path`に同じSDK directoryを指定します。directory直下の`platform-tools/adb`が実行できることを確認してください。

### Godot .NET 4.6.3-stable

[Godot 4.6.3-stable release](https://github.com/godotengine/godot/releases/tag/4.6.3-stable)から、OSに合う`.NET`／`mono`版editorを取得します。標準版GodotではC#をbuildできません。

Godot本体に加え、同じreleaseの`mono_export_templates`を取得し、Godotの`Manage Export Templates`から導入します。標準版export templatesではなく、Mono版である必要があります。インストール後、`4.6.3.stable.mono`のtemplate directoryに`android_debug.apk`と`android_source.zip`があることを確認します。

以降では.NET版Godot実行ファイルを`GODOT_BIN`へ設定します。例:

```bash
# macOSの例
GODOT_BIN="/Applications/Godot_mono.app/Contents/MacOS/Godot"

# Linuxでrelease archiveを展開した場合の例
# GODOT_BIN="/path/to/Godot_v4.6.3-stable_mono_linux_x86_64"

"$GODOT_BIN" --version
```

version出力が`4.6.3.stable.mono`で始まることを確認してください。

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

すべてDebug APKです。debug keystoreはGodot／Android build環境の標準Debug署名を使用し、release keyやcredentialは不要です。

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
```

packageは3 preset共通で`com.afjk.scenesyncgodot`です。コマンドから起動する場合は次を使用できます。

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

### PICO 4 Ultra

- `PICO 4 Ultra Debug` presetはPICO OpenXR loaderを使用し、Meta loaderは無効です。
- PICO OSを更新し、Developer Mode、USB debugging、Video See-Through、Hand Trackingを有効にします。
- `/interaction_profiles/bytedance/pico4_controller`のaim／grip trackingを確認します。

### VIVE Focus Vision

- `VIVE Focus Vision Debug` presetはKhronos loaderのHTC modeを使用し、Meta／PICO loaderは無効です。
- OpenXR Vendors 5.1.0-stableではHTC Hand TrackingがAndroid manifest上でrequiredになります。
- passthroughは`XR_HTC_passthrough`のplanar layerを使用します。projected passthroughやcamera image取得は対象外です。

現時点ではQuest 3、PICO 4 Ultra、VIVE Focus Visionのすべてで実機検証が未完了です。端末別項目は確認すべき受け入れ項目であり、動作済みという意味ではありません。

## 8. Scene Sync接続を確認する

1. headsetアプリを起動します。
2. `XROrigin3D`配下の小型composition-layer panelで、右controllerのaim rayとtriggerを使い`Room`と端末を識別できる`Nickname`を入力します。
3. `Connect`を選択します。接続後、panelが縮小することを確認します。
4. PCまたはスマートフォンで `https://afjk.jp/scenesync/?room=<room>` を開きます。
5. Web viewerとheadset双方にparticipantが表示されることを確認します。
6. Web／Unity側からprimitiveを追加し、headsetの`SceneSyncRoot`以下へ同じ位置・回転・scaleで生成されることを確認します。
7. transform変更、削除、後参加時の`scene-state`復元を確認します。
8. GLB objectとLoomlet graphはprimitive同期の成立後に確認します。
9. headsetをpause／resumeし、pause中にreconnect loopが発生せず、resume後に安全に再接続できることを確認します。

`SceneSyncRoot`はXR rig外にあり、`XROrigin3D`、camera、hands、controllers、aim rayは同期対象に含まれません。

## 9. Pull Requestのartifact

`main`向けPull Requestまたは`workflow_dispatch`で、`.github/workflows/build-android-xr.yml`が上記と同じ固定versionを使って3 presetをbuildします。

| Preset | Artifact | APK |
| --- | --- | --- |
| `Meta Quest 3 Debug` | `scene-sync-godot-quest3-debug` | `scene-sync-godot-quest3-debug.apk` |
| `PICO 4 Ultra Debug` | `scene-sync-godot-pico4-ultra-debug` | `scene-sync-godot-pico4-ultra-debug.apk` |
| `VIVE Focus Vision Debug` | `scene-sync-godot-vive-focus-vision-debug` | `scene-sync-godot-vive-focus-vision-debug.apk` |

artifactの保存期間は14日です。このworkflowはDebug APK専用です。

## 10. トラブルシューティング

### `Godot.NET.Sdk`をrestoreできない

- `dotnet --list-sdks`に9.0以上が表示されることを確認します。
- NuGetへ接続できることを確認します。脆弱性情報だけ取得できない`NU1900`はbuildを妨げない場合がありますが、package本体を取得できない場合はrestoreに失敗します。
- `SceneSyncGodot.csproj`のSDK versionを勝手に`latest`へ変更しないでください。

### C# buildは通るがGodotでassemblyをloadできない

- 標準版ではなくGodot `.NET 4.6.3-stable`を使用します。
- `dotnet build`後にGodotの`--import`を実行します。
- Godot本体、Mono export templates、`Godot.NET.Sdk`のversionが`4.6.3`で揃っていることを確認します。

### `No export template found`／Android template error

- `4.6.3-stable`のMono export templatesを導入します。標準版templatesや異なるpatch versionは使用しません。
- `android_debug.apk`と`android_source.zip`が同じtemplate directoryにあることを確認します。
- `--install-android-build-template`を付けるか、Godot editorからAndroid Build Templateを導入します。

### JDK／Android SDK／Gradle error

- Java SDK PathがJDK 17を指していることを確認します。
- Android SDK Pathと`<ANDROID_SDK_ROOT>`が同じdirectoryを指していることを確認します。
- Platform 35、Build-Tools 35.0.1、CMake 3.10.2.4988404、NDK 28.1.13356709を再確認します。
- 初回Gradle buildには依存物を取得するネットワーク接続が必要です。

### OpenXR Vendorsのexport項目がない

- `addons/godotopenxrvendors/plugin.gdextension`の存在を確認します。
- OpenXR Vendorsが`5.1.0-stable`であることを確認し、配置後にGodotを再起動または再importします。
- presetごとにMeta、PICO、Khronosのうち対象loaderだけが有効であることを確認します。

### APKは起動するがpassthrough／trackingが動かない

- 端末OS／firmwareを更新し、アプリ権限、passthrough、Hand Trackingを端末側で有効にします。
- `adb logcat`でGodotとOpenXR runtimeの初期化errorを確認します。
- 実行中runtimeが必要なpassthrough、Hand Tracking、controller interaction profileを提供していることを確認します。

### Scene Syncが接続できない／詳細errorがpanelに出ない

Scene Sync addon `0.2.0`の公開APIは接続状態、peer、object追加／削除signalを提供しますが、WebSocket接続失敗やsend失敗の詳細を返すpublic error signal／`last_error`は提供していません。そのため統合UIだけでは詳細原因を表示できない場合があります。

次を確認してください。

- Android presetのInternet permissionが有効であること
- roomとnicknameが意図した値であること
- `wss://afjk.jp/presence`へ端末のネットワークから接続できること
- `adb logcat`またはGodot consoleの`[SceneSync]` warning

詳細errorが必要な場合でも、vendor済み`addons/scene_sync`をこのrepositoryだけで直接改変しないでください。SDK側にerror公開が必要なら`afjk/afjk.jp`で修正し、新しいcommitへpinを更新します。

### .NET Android固有のAOT／Loomlet error

Godot C#のAndroid exportはexperimentalです。desktop build成功後にだけAndroidで失敗する場合は、最小C# smoke node、Scene Sync基本通信、Loomlet runtimeの順に切り分けます。vendor済みSDKからC#ファイルを削除して回避せず、SDKの問題は`afjk/afjk.jp`で修正します。
