# Scene Sync Godot

Scene SyncのGodot addonを、Meta Quest 3、PICO 4 Ultra、VIVE Focus Vision向けの最小MRアプリへ統合するリポジトリです。OpenXRのpassthrough、Hand Tracking、controller trackingと、同じroomに参加したWeb／Unityクライアントとのscene同期を対象にしています。

## 固定しているsource

- MR基盤: [`afjk/MR-Godot-Template`](https://github.com/afjk/MR-Godot-Template/tree/af6ac1233a939b2e09510afc0336459e8630288d) commit `af6ac1233a939b2e09510afc0336459e8630288d`
- Scene Sync SDK: [`afjk/afjk.jp` のGodot addons](https://github.com/afjk/afjk.jp/tree/d1a7362028577fce55d120a35690e174580eec99/godot/addons) commit `d1a7362028577fce55d120a35690e174580eec99`、addon `0.5.0`
- Scene Sync Rapier runtime: [`afjk/godot-rapier-physics`](https://github.com/afjk/godot-rapier-physics/releases/tag/scenesync-v0.8.28-r0.30.0.3) tag `scenesync-v0.8.28-r0.30.0.3`、commit `b0578430c3b975bcf3bc0ee86df0450b51a57eb0`、Rapier core `0.30.0`

SDKのsource of truthは`afjk/afjk.jp`です。このリポジトリでは上記commitの`godot/addons/scene_sync`と`godot/addons/godot-rapier3d`を、それぞれ`addons/scene_sync`と`addons/godot-rapier3d`へ完全vendorしています。Rapier GDExtensionが利用できるplatformでは固定timestepのScene Sync physicsを実行し、利用できないplatformやextension欠落時もphysics metadataの同期を継続してsimulationだけを無効化します。

## 対応端末

- Meta Quest 3
- PICO 4 Ultra
- VIVE Focus Vision

いずれもAndroid arm64のDebug APKを対象とします。現時点では3端末とも実機での起動・passthrough・Scene Sync接続を未検証です。CIやローカルでのbuild成功は実機動作確認の代わりにはなりません。

## Roomへ接続する

1. アプリを起動し、小型のScene Sync panelを表示します。
2. 右controllerのaim rayを`Room`または`Nickname`へ向け、triggerで選択して入力します。
3. `Connect`を選択します。接続後、panelはMR表示を遮らない大きさへ縮小します。
4. ブラウザで `https://afjk.jp/scenesync/?room=<同じroom>` を開き、同じroomへ参加します。

受信objectはXR rig外の`SceneSyncRoot`以下へ生成されます。headsetのpause/resume時は接続処理を停止・再開し、XR origin自体は同期対象にしません。

このXRアプリはShared PlaybackのFollower Onlyとして動作し、Controllerを取得しません。同じroomに有効なControllerがいる間はAnimation、Loomlet、Rapierが共通のShared Timeへ追従し、Controllerがいない場合やrelease／切断／lease失効後は、表示時刻と物理状態を維持したままlocal monotonic timeで進行します。

## Pull RequestのAPKを取得する

`main`向けPull Requestでは`Build Android XR Debug APKs` workflowが3 presetをbuildします。workflow完了後、Actions runの`Artifacts`から次を取得します。

- `scene-sync-godot-quest3-debug`
- `scene-sync-godot-pico4-ultra-debug`
- `scene-sync-godot-vive-focus-vision-debug`

Actions画面の`Run workflow`から手動実行もできます。生成物はDebug APKのみで、release用credentialは使用しません。

## 詳細ドキュメント

- [ローカルbuild、ADB install、接続確認](Docs/BUILDING.md)
- [Scene Sync SDKのpinと更新方法](Docs/SCENE_SYNC_SDK.md)
