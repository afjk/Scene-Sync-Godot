# Scene Sync Godot

Scene SyncのGodot addonを、Meta Quest 3、PICO 4 Ultra、VIVE Focus Vision向けの最小MRアプリへ統合するリポジトリです。OpenXRのpassthrough、Hand Tracking、controller trackingと、同じroomに参加したWeb／Unityクライアントとのscene同期を対象にしています。

## 固定しているsource

- MR基盤: [`afjk/MR-Godot-Template`](https://github.com/afjk/MR-Godot-Template/tree/af6ac1233a939b2e09510afc0336459e8630288d) commit `af6ac1233a939b2e09510afc0336459e8630288d`
- Scene Sync SDK: [`afjk/afjk.jp` の `godot/addons/scene_sync`](https://github.com/afjk/afjk.jp/tree/54b911cdccb40d22de3a55fd7c6853989d4a5ed3/godot/addons/scene_sync) commit `54b911cdccb40d22de3a55fd7c6853989d4a5ed3`、addon `0.3.3`

SDKのsource of truthは`afjk/afjk.jp`です。このリポジトリでは上記commitを`addons/scene_sync`へvendorしています。

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

## Pull RequestのAPKを取得する

`main`向けPull Requestでは`Build Android XR Debug APKs` workflowが3 presetをbuildします。workflow完了後、Actions runの`Artifacts`から次を取得します。

- `scene-sync-godot-quest3-debug`
- `scene-sync-godot-pico4-ultra-debug`
- `scene-sync-godot-vive-focus-vision-debug`

Actions画面の`Run workflow`から手動実行もできます。生成物はDebug APKのみで、release用credentialは使用しません。

## 詳細ドキュメント

- [ローカルbuild、ADB install、接続確認](Docs/BUILDING.md)
- [Scene Sync SDKのpinと更新方法](Docs/SCENE_SYNC_SDK.md)
