# AppMixer

AppMixerは、アプリごとの音量と出力全体の音質を調整できる、macOSのメニューバーアプリです。

- アプリ別の音量を0〜200%で調整・ミュート
- 低音・中音・高音を各±12 dBで調整
- メニューバーに現在の出力先を表示し、macOSで出力先を変えると自動で追従
- 音声処理は起動時にオフ。再生音声の保存や送信は行いません

## 動作環境

macOS 26以降。音声処理は内蔵出力・USB・Bluetooth・HDMI・DisplayPort・Thunderboltのうち、対応するステレオ機器で使えます。通話モードでモノラルになった機器や仮想オーディオ出力では、音量・EQ処理を一時停止してmacOSの通常再生に戻します。ビルドにはSwift 6.2以降が必要です。

## ダウンロード

[GitHub Releases](https://github.com/kasuuuu4423/AppMixer/releases/latest) の `AppMixer-v*-macOS-arm64.zip` を展開し、`AppMixer.app` を開きます。配布版はApple Silicon搭載Mac向けで、Appleの公証は受けていません。開けない場合は、下記の手順でローカルビルドできます。

## ソースからビルド

```sh
bash Packaging/build-app.sh
open dist/AppMixer.app
```

メニューバーのスライダーアイコンから、音量やEQを設定し、「音声処理」をオンにします。初回はmacOSからシステムオーディオの録音許可を求められます。アプリが一覧に出ていない場合は、そのアプリで一度音を鳴らしてください。

## テスト

```sh
swift test
```

## リリース

`Packaging/Info.plist` のバージョンと一致する `vX.Y.Z` タグをGitHubにプッシュすると、GitHub Actionsがテスト、ビルド、ZIPの公開を行います。
