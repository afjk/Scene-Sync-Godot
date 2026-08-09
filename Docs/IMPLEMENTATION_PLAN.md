# Scene Sync Godot MR Integration 実装計画

## 1. 目的

`Scene-Sync-Godot`は、Scene SyncのGodot SDKをMeta Quest 3、PICO 4 Ultra、VIVE Focus Vision向けGodot MRアプリへ統合し、実機で動作するDebug APKを提供するリポジトリとする。

このリポジトリはScene Sync SDK本体を開発する場所ではない。SDKのsource of truthは`afjk/afjk.jp`に置き、このリポジトリではSDKの固定バージョンを利用してMR統合、端末設定、ビルド、動作確認を行う。

## 2. リポジトリの責務

| リポジトリ | 責務 |
| --- | --- |
| `afjk/MR-Godot-Template` | Scene Sync非依存の最小MR/XRテンプレート |
| `afjk/afjk.jp` | Scene Sync server、protocol、Godot addon、Unity packageのsource of truth |
| `afjk/Scene-Sync-Godot` | Scene Sync Godot addonを組み込んだMRアプリ、Android export preset、CI、実機向け説明 |

このリポジトリ固有の不具合とSDK本体の不具合を混在させないこと。

- XR scene、Android export、MR UI、統合adapterの変更はこのリポジトリで行う。
- `addons/scene_sync`内部の不具合は原則として`afjk.jp`で修正する。
- SDK修正後、このリポジトリが参照するcommitを更新する。
- vendor済みSDKへ直接変更を加える場合は、同じ修正を`afjk.jp`へ先に反映する。

## 3. 入力となる既存実装

### MRテンプレート

- Repository: <https://github.com/afjk/MR-Godot-Template>
- 対象branch: 原則`main`
- 必要機能:
  - Meta Quest 3 MR passthrough
  - PICO 4 Ultra MR build
  - VIVE Focus Vision MR build
  - OpenXR
  - Hand Tracking
  - Controller tracking
  - Controller位置を示す球体
  - aim poseに追従するRay
  - Pull Request時の3機種Debug APK build

実装開始時に`main`へ必要なPRがマージ済みか確認する。未マージのfeature branchを黙って取り込まず、採用するsource commitをこの文書またはREADMEへ記録する。

### Scene Sync Godot addon

- Repository: <https://github.com/afjk/afjk.jp>
- Source path: `godot/addons/scene_sync`
- 初期調査時のaddon version: `0.2.0`
- 初期pin候補: `a2fcdb5cce6e73e40704334625f6d616247b3885`
- Addon README: <https://github.com/afjk/afjk.jp/tree/main/godot/addons/scene_sync>
- Protocol docs: <https://github.com/afjk/afjk.jp/blob/main/docs/scene-sync-spec.md>

実装開始時に最新の`main`と上記pin候補を比較する。最新を採用する場合も必ずcommit SHAで固定する。

## 4. SDK取り込み方針

初期実装では`godot/addons/scene_sync`をこのリポジトリの`addons/scene_sync`へvendorする。

Git submoduleは使用しない。`afjk.jp`はサーバー、Web、Unity、Blenderなどを含むモノレポであり、submoduleでは不要な全体を取得することになるためである。

次の管理ファイルを用意する。

```text
Docs/SCENE_SYNC_SDK.md
scripts/update_scene_sync_addon.sh
scene-sync-version.txt
```

`scene-sync-version.txt`には参照元repository、commit SHA、addon versionを記録する。

更新スクリプトは次を満たすこと。

- 引数またはファイルでcommit SHAを固定する。
- `afjk.jp`の`godot/addons/scene_sync`だけを取得する。
- 更新前にローカル変更がある場合は失敗する。
- vendor先を削除してから置換し、削除済みファイルが残らないようにする。
- 実行後に参照commitを更新する。
- SDKの取得失敗時に既存vendorを壊さない。

CI中に常にSDK最新版を取得する方式にはしない。cloneした状態だけで再現可能なbuildにする。

## 5. 想定ディレクトリ構成

```text
Scene-Sync-Godot/
├── .github/
│   └── workflows/
│       └── build-android-xr.yml
├── Docs/
│   ├── IMPLEMENTATION_PLAN.md
│   ├── BUILDING.md
│   └── SCENE_SYNC_SDK.md
├── addons/
│   └── scene_sync/
├── scenes/
│   ├── main.tscn
│   └── scene_sync_status_panel.tscn
├── scripts/
│   ├── scene_sync_bootstrap.gd
│   └── update_scene_sync_addon.sh
├── scene-sync-version.txt
├── export_presets.cfg
├── openxr_action_map.tres
├── project.godot
└── README.md
```

実際のMRテンプレート構成を優先し、不要な移動やrenameは避ける。

## 6. Godotと.NET要件

Scene Sync addonはLoomlet behavior graph実行のためC#を含む。標準版Godotではなく.NET版Godotを使用する。

初期目標:

- Godot .NET 4.6系
- MRテンプレートと同じGodot patch version
- .NET SDK 9以上
- .NET対応Android export templates
- JDK 17
- Android SDK、NDK、CMakeはMRテンプレートのbuild workflowと同じ固定version
- Android arm64

GodotのC# Android exportはexperimentalである。デスクトップで成功してもAndroidで失敗する可能性があるため、最初に最小sceneで.NET Android APKをbuildして技術成立性を確認する。

実装順序を次のようにする。

1. MRテンプレートをSDKなしで.NET版GodotからAndroid exportする。
2. Scene Sync addonを有効化し、C# compileを通す。
3. `SceneSyncManager`を追加した空のruntime sceneをAndroid exportする。
4. Scene Sync接続を有効化する。
5. GLB、Loomlet、同期対象を段階的に有効化する。

最初から全機能を同時に有効化して原因を不明瞭にしない。

## 7. Scene構成

Scene Sync対象とXR rigを分離する。

```text
Main
├── XROrigin3D
│   ├── XRCamera3D
│   ├── LeftHand / LeftController
│   ├── RightHand / RightController
│   └── AimRays
├── SceneSyncRoot
├── SceneSyncManager
└── SceneSyncStatusPanel
```

必須ルール:

- `SceneSyncManager.sync_root`は`SceneSyncRoot`を参照する。
- `XROrigin3D`、camera、hands、controllers、Rayを同期対象に含めない。
- remote objectは`SceneSyncRoot`以下へ生成する。
- Scene Sync受信データによってXR originが移動しないようにする。
- Unity由来GLBの`asset.visualBasis`補正をaddonへ任せ、統合側で二重補正しない。
- Scene Sync objectの座標単位はmeterとして扱う。

## 8. Scene Sync runtime設定

`SceneSyncManager`へ最低限次を設定する。

```text
presence_url = wss://afjk.jp/presence
room = user selected room code
nickname = device identifiable name
sync_root = SceneSyncRoot
auto_connect = false
```

接続先URLをコードへ複数箇所ハードコードしない。ProjectSettingsまたは単一config resourceから供給する。

Room codeは秘密情報ではないが、ユーザー固有値をrepositoryへ固定しない。初期buildでは次のどちらかを実装する。

- 推奨: MR内の小さなstatus panelでroom codeを入力し、Connectを実行する。
- 最小fallback: exported propertyにtest roomを設定し、READMEに変更方法を書く。

Android上で文字入力UIが実用にならない場合は、固定test roomまたは起動引数以外の設定導線を設計する。端末ごとのnicknameには`Quest3`、`PICO4Ultra`、`VIVEFocusVision`などを含め、参加者一覧で区別できるようにする。

## 9. 最小UI

最初のbuildで必要な表示は次だけとする。

- Connection state
- Room code
- Nickname
- Connect / Disconnect
- Last error
- Received object count

高度なEditor操作、object inspector、scene編集UIは実装しない。Scene Sync SDKのEditor DockとMR runtime UIを混同しない。

UIがMR表示を遮らないよう、camera前方へ追従する常設巨大panelは避ける。初期接続後は縮小または非表示にできるようにする。

## 10. Runtime統合

最小のruntime成立条件:

- WSSでpresence serverへ接続できる。
- 同じroomのWeb viewerまたはUnity clientを認識できる。
- join後に`scene-request`を送信できる。
- `scene-state`からprimitiveまたはGLB objectを生成できる。
- `scene-delta`でposition、rotation、scaleを更新できる。
- `scene-remove`でremote objectを削除できる。
- disconnect後に安全に再接続できる。
- headset suspend/resume後に接続状態が破綻しない。

Android lifecycle対応では、pause中に無制限なreconnect loopを発生させない。

## 11. Android export preset

MRテンプレートの3 presetを維持し、package nameをこのアプリ固有に変更する。

推奨package name:

```text
com.afjk.scenesyncgodot
```

preset例:

- `Meta Quest 3 Debug`
- `PICO 4 Ultra Debug`
- `VIVE Focus Vision Debug`

確認項目:

- Internet permission
- arm64有効
- OpenXR有効
- passthrough関連feature
- Hand Tracking関連feature
- 各vendorのinteraction profile
- Debug keystoreはCIで生成または標準debug keystoreを使用
- release keyやcredentialをcommitしない

## 12. GitHub Actions

Pull Request作成時と手動実行で3機種のDebug APKをbuildする。

```yaml
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
```

Workflow要件:

- Godot .NET版をversion固定で取得する。
- 対応する.NET Android export templatesを取得する。
- .NET SDK 9以上をsetupする。
- JDK 17とAndroid SDKをsetupする。
- `dotnet restore`と`dotnet build`を実行する。
- Godot importを完了させてからexportする。
- 3 presetをmatrix buildする。
- APKを機種名付きartifactとしてuploadする。
- SDKやGodotの`latest`を参照しない。
- `yes | sdkmanager`のようにBroken pipeを起こし得る処理を避ける。
- `sdkmanager`は絶対pathまたはsetup済み`ANDROID_HOME`配下から呼ぶ。

artifact名例:

```text
scene-sync-godot-quest3-debug
scene-sync-godot-pico4-ultra-debug
scene-sync-godot-vive-focus-vision-debug
```

## 13. READMEとBuild手順

READMEには次だけを簡潔に記載する。

- このrepositoryの目的
- Scene Sync SDKのsource repositoryとpin
- 対応端末
- roomへの接続方法
- APK artifactの取得方法
- 詳細build手順へのリンク

`Docs/BUILDING.md`には次を記載する。

- Godot .NET version
- .NET SDK version
- JDK version
- Android SDK packages
- export templatesの導入
- local Debug APK build command
- Quest、PICO、VIVEへのADB install方法
- package name
- よくある.NET Android exportエラー
- Scene Sync接続確認手順

## 14. テスト方針

### 最初の技術検証

- Godot .NETでprojectを開ける。
- addonのGDScriptとC#がcompileできる。
- Android Debug APKが生成できる。
- Quest 3で起動できる。
- 起動直後にC# runtime errorがない。

Quest 3で成立後、PICO 4 Ultra、VIVE Focus Visionへ展開する。

### Scene Sync接続確認

1. `https://afjk.jp/scenesync/?room=<room>`を開く。
2. headset appを同じroomへ接続する。
3. participantが双方に表示されることを確認する。
4. WebまたはUnityからprimitiveを追加する。
5. headsetに同じ位置、回転、scaleで表示されることを確認する。
6. transform変更と削除が反映されることを確認する。
7. headsetを後参加させ、`scene-state`で復元されることを確認する。

### 端末別確認

- Quest 3: passthrough、controller、Hand Tracking、Scene Sync
- PICO 4 Ultra: passthrough、controller、Scene Sync
- VIVE Focus Vision: passthrough、controller、Scene Sync

Hand Tracking中にcontroller visualが残らない既存仕様を維持する。

## 15. 受け入れ条件

- `main`へのPull Requestで3種類のDebug APKが自動buildされる。
- Quest 3、PICO 4 Ultra、VIVE Focus Visionの少なくとも起動確認が記録される。
- Quest 3でScene Syncの接続、scene-state受信、transform同期が確認できる。
- `MR-Godot-Template`へScene Sync依存を追加していない。
- SDKのsource commitが記録され、cloneだけで同じbuildを再現できる。
- credential、build artifact、`.godot`、Android生成物がcommitされていない。
- READMEと`Docs/BUILDING.md`だけで別PCからbuildできる。

## 16. 既知リスクとfallback

### .NET Android export

GodotのC# Android対応はexperimentalである。端末またはAOTでLoomlet runtimeが失敗する可能性がある。

Fallback:

1. 問題を最小の.NET Android sceneで再現する。
2. Scene Sync addonの基本通信とLoomletを切り分ける。
3. Loomletをoptionalにする必要がある場合は`afjk.jp`側のSDK設計として修正する。
4. この統合repositoryだけでC#ファイルを削除またはforkしない。

### Mobile GLB処理

Editorで動作するGLB export/importがAndroid runtimeで同じように動くとは限らない。最初はremote primitiveとGLB importを優先し、headsetからのGLB publishは別段階にする。

### Networkとlifecycle

WSS切断、Wi-Fi切替、headset sleepにより再接続が必要になる。無制限reconnectや毎frame接続処理を避け、backoffを設ける。

### Performance

MR headset上で大量object、GLB decode、Loomlet、passthroughを同時実行すると負荷が高い。初期受け入れでは少数objectを対象とし、性能改善は計測後に行う。

## 17. 実装順序

1. MRテンプレートの採用commitを決めて新規repositoryへ取り込む。
2. repository名、package name、READMEをScene Sync用に変更する。
3. 標準Godot buildを.NET buildへ切り替える。
4. SDKなしで3機種向けAPK buildを成立させる。
5. Scene Sync addonを固定commitからvendorする。
6. addonを有効化し、desktopでGDScript/C# compileを成立させる。
7. Androidでaddon込みの最小sceneを起動する。
8. `SceneSyncRoot`と`SceneSyncManager`を追加する。
9. room接続とstatus表示を追加する。
10. Web viewerとのscene-state、add、delta、removeを確認する。
11. Quest 3実機で確認する。
12. PICO 4 UltraとVIVE Focus Visionで確認する。
13. Pull Request向け3機種matrix buildを追加する。
14. `Docs/BUILDING.md`とSDK更新手順を完成させる。

## 18. 実装エージェントへの注意

- 最初にこの文書、対象repositoryのREADME、参照元2 repositoryのREADMEを読む。
- 既存MRテンプレートを再設計せず、Scene Sync統合に必要な差分だけ追加する。
- SDK内部の修正が必要なら、統合側のworkaroundより先に`afjk.jp`側の責務か判断する。
- 端末固有分岐をScene Sync通信コードへ混ぜない。
- build成功だけで完了とせず、少なくともQuest 3で接続とscene受信を確認する。
- commitやpushはユーザーの指示に従う。
