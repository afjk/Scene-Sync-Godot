# Scene Sync Godot

Scene SyncのGodot addonを、Meta Quest 3、PICO 4 Ultra、VIVE Focus Vision向けの最小MRアプリへ統合するリポジトリです。OpenXRのpassthrough、Hand Tracking、controller trackingと、同じroomに参加したWeb／Unityクライアントとのscene同期を対象にしています。

## 固定しているsource

- MR基盤: [`afjk/MR-Godot-Template`](https://github.com/afjk/MR-Godot-Template/tree/5d21cf1c7dcd7c1995dff28d02021eb412eda606) commit `5d21cf1c7dcd7c1995dff28d02021eb412eda606`
- Scene Sync SDK: [`afjk/afjk.jp` のGodot addons](https://github.com/afjk/afjk.jp/tree/3385e633c1710feb11636ad278ad106fe490ade5/godot/addons) commit `3385e633c1710feb11636ad278ad106fe490ade5`、addon `0.5.1`
- Scene Sync Rapier runtime: [`afjk/godot-rapier-physics`](https://github.com/afjk/godot-rapier-physics/releases/tag/scenesync-v0.8.28-r0.30.0.3) tag `scenesync-v0.8.28-r0.30.0.3`、commit `b0578430c3b975bcf3bc0ee86df0450b51a57eb0`、Rapier core `0.30.0`
- Gaussian Splat renderer: [`shiena/godot-gsplat`](https://github.com/shiena/godot-gsplat/tree/dfc8df4893f0f6e26c847590ff1669fa8404da6d) commit `dfc8df4893f0f6e26c847590ff1669fa8404da6d`、addon `0.1.0`

SDKのsource of truthは`afjk/afjk.jp`です。このリポジトリでは上記commitの`godot/addons/scene_sync`と`godot/addons/godot-rapier3d`を、それぞれ`addons/scene_sync`と`addons/godot-rapier3d`へ完全vendorしています。Rapier GDExtensionが利用できるplatformでは固定timestepのScene Sync physicsを実行し、利用できないplatformやextension欠落時もphysics metadataの同期を継続してsimulationだけを無効化します。

`godot-gsplat`はScene Sync SDKとは別の固定dependencyとして、addon、GDExtension descriptor、Linux x86_64、macOS arm64、Android arm64のnative libraryをvendorしています。Android libraryは固定Cargo.lockとcompatibility patchを使い、NDK `28.1.13356709`でbuildしています。build provenanceは`addons/godot_gsplat/SCENESYNC_BUILD.txt`に記録しています。

## 対応端末

- Meta Quest 3
- PICO 4 Ultra
- VIVE Focus Vision
- Android XR（MR基盤から取り込んだpresetのみ。Scene Sync側での確認は未実施）

いずれもAndroid arm64のDebug APKを対象とします。Quest 3ではScene Syncから受信したGaussian Splatがpoint-preview fallbackとして表示されるところまで実機確認済みです。Vulkan Mobileとnative `godot-gsplat`による実Gaussian描画、stereo sorting、passthroughとの併用、性能は未検証です。CIやローカルでのbuild成功は実機動作確認の代わりにはなりません。

## MR基盤から取り込んだOpenXRの挙動

`afjk/MR-Godot-Template`の`5d21cf1`時点の内容を取り込んでいます。Scene Sync固有の実装（demo cube削除、`SceneSyncRoot`、status panel）は維持したうえで、次が有効です。

- runtimeが提供するコントローラー3Dモデルの表示。core `XR_EXT_render_model`（`OpenXRRenderModelManager`）とMeta `XR_FB_render_model`の両方を用意し、モデルを返した方を採用します。どちらも非対応なら従来の球マーカーへfallbackします。
- `session_begun`で`maximum_refresh_rate`（既定90Hz）以下の最良のdisplay refresh rateを選び、`Engine.physics_ticks_per_second`を追従させます。Scene SyncのRapier runtimeは自前の固定timestepで進むため、この変更はdeterminismに影響しません。
- Local Floor reference space、foveated rendering（High／dynamic）、MSAA 2xの推奨project設定。
- コントローラー由来のHand Trackingでは`CONFORM_TO_CONTROLLER`、光学式では`UNOBSTRUCTED`へ`set_motion_range()`を切り替え。
- 各export presetの`Enable Openxr Validation Layers`（既定は無効）と`xr/openxr/extensions/debug_utils=2`。

XRフォーカスの扱いだけMR基盤から変更しています。上流の`scripts/main.gd`はフォーカス喪失時に`process_mode`を`PROCESS_MODE_DISABLED`にしてsubtree全体を止めますが、このリポジトリでは`SceneSyncManager`が同じsubtreeにありWebSocketのpollを続ける必要があるため、`main.gd`自身の`_process`だけを止めます。アプリのbackground遷移は従来どおり`scene_sync_bootstrap.gd`の`NOTIFICATION_APPLICATION_PAUSED`で切断・再接続を扱います。

## Roomへ接続する

1. アプリを起動し、小型のScene Sync panelを表示します。
2. 右controllerのaim rayを`Room`または`Nickname`へ向け、triggerで選択して入力します。
3. `Connect`を選択します。接続後、panelはMR表示を遮らない大きさへ縮小します。
4. ブラウザで `https://afjk.jp/scenesync/?room=<同じroom>` を開き、同じroomへ参加します。

受信objectはXR rig外の`SceneSyncRoot`以下へ生成されます。headsetのpause/resume時は接続処理を停止・再開し、XR origin自体は同期対象にしません。

このXRアプリはShared PlaybackのFollower Onlyとして動作し、Controllerを取得しません。同じroomに有効なControllerがいる間はAnimation、Loomlet、Rapierが共通のShared Timeへ追従し、Controllerがいない場合やrelease／切断／lease失効後は、表示時刻と物理状態を維持したままlocal monotonic timeで進行します。

## Gaussian Splatを表示する

Scene Sync Godotは`KHR_gaussian_splatting` GLBを受信し、Vulkan Mobile上の`godot-gsplat`で実Gaussian描画します。`.ply`、`.sog`、`.spz`などはGodotへ直接送らず、SceneSync Webへ追加して`KHR_gaussian_splatting` GLBへ正規化します。

native backendが正常に選択されると、Godot logに`Gaussian Splat backend registered: godot-gsplat`が出力されます。`showing point-cloud preview`が出る場合は実rendererへ入っていません。QuestではXR profileが自動選択され、splat数に応じたbudget、SH1、head-center sorting、center depthを使用します。

## Pull RequestのAPKを取得する

`main`向けPull Requestでは`Build Android XR Debug APKs` workflowが4 presetをbuildします。workflow完了後、Actions runの`Artifacts`から次を取得します。

- `scene-sync-godot-quest3-debug`
- `scene-sync-godot-pico4-ultra-debug`
- `scene-sync-godot-vive-focus-vision-debug`
- `scene-sync-godot-android-xr-debug`

Actions画面の`Run workflow`から手動実行もできます。生成物はDebug APKのみで、release用credentialは使用しません。

あわせて`Static Checks` workflowが、`addons/`以外の追跡中`.gd`へ`gdformat --diff`と`gdlint`を実行します。vendorしている`addons/scene_sync`、`addons/godot-rapier3d`、`addons/godot_gsplat`は対象外です。ローカルでは次で同じ確認ができます。

```bash
pip install 'gdtoolkit==4.*'
gdformat --diff scripts/
gdlint scripts/
```

## 詳細ドキュメント

- [ローカルbuild、ADB install、接続確認](Docs/BUILDING.md)
- [Scene Sync SDKのpinと更新方法](Docs/SCENE_SYNC_SDK.md)
