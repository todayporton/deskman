# deskman

macOS のデスクトップ（Spaces）に名前を付けて、名前で瞬時に移動する小さなツール。名前は各デスクトップの UUID に紐づくので、並べ替えや増減があってもずれない。

## インストール

```sh
bash scripts/bundle.sh
cp -R dist/Deskman.app /Applications/
ln -s /Applications/Deskman.app/Contents/MacOS/deskman ~/.local/bin/deskman
```

移動には Deskman.app の常駐とアクセシビリティ権限が必要。`open /Applications/Deskman.app` で起動し、システム設定 > プライバシーとセキュリティ > アクセシビリティ で Deskman.app を許可する。メニューの「ログイン時に起動」で自動起動にできる。

`deskman go` はローカルソケットで常駐アプリに移動を依頼する。権限は Deskman.app だけにあればよく、ターミナルや Herdr には不要。`scripts/bundle.sh` の既定はアドホック署名で、再ビルドして置き換えると許可し直しが必要になることがある。`CODESIGN_IDENTITY="証明書の名前" bash scripts/bundle.sh` のように自分の証明書で署名すれば、再ビルドしても同じアプリとして扱われる想定。Developer ID 署名と公証はしていないので、ビルド済みのアプリの配布には向かない。

## 使い方

```
deskman                         メニューバーアプリとして起動
deskman list [--json] [--all]   一覧（* は現在地、+ は他のディスプレイで表示中）
deskman current [--json]        現在のデスクトップ
deskman go [--restore-cursor] [--restore-focus] <名前|番号|UUID>
                                移動
deskman next [--wrap] [--cursor] [--restore-cursor] [--restore-focus]
                                右隣へ移動
deskman prev [--wrap] [--cursor] [--restore-cursor] [--restore-focus]
                                左隣へ移動
deskman rename <対象> <名前>    名前を付ける（"" で解除）
deskman rename --forget <名前>  一覧にない名前を消す
```

`next` と `prev` は、既定ではアクティブなウィンドウのあるディスプレイで、`--cursor` を付けるとカーソルのあるディスプレイで隣へ移動する。他のディスプレイへは進まず、端では終了コード 2 で失敗する。`--wrap` を付けると反対の端へ回り込む。フルスクリーンのデスクトップも並びどおりに数える。連続で呼ぶと、呼んだ回数だけ進む。

`--restore-cursor` は、移動のためにカーソルを別のディスプレイへ動かした場合に、移動後に元の位置へ戻す。`--restore-focus` は、移動でキーボードのフォーカスが他のウィンドウへ移った場合に、移動前のウィンドウへ戻す。戻すのは移動前のウィンドウが画面に出ているときだけで、移動のコマンドはフォーカスを戻すのを待たずに終わる。次の移動が始まると、戻す処理は取りやめる。

番号は今の並びの順番なので、並べ替えるとずれる。ずらしたくない呼び出しでは名前か UUID を使う。

## 終了コード

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 1 | その他のエラー |
| 2 | 見つからない（`next`/`prev` では端にいる） |
| 3 | 今の一覧にない（ディスプレイが外れている、または削除された） |
| 4 | アクセシビリティ権限がない |
| 5 | 移動を確認できない |
| 6 | 名前の重複 |
| 7 | Deskman.app が起動していない |
| 64 | 引数の誤り |

## 制限

- macOS の非公式 API（`CGSCopyManagedDisplaySpaces`、Dock スワイプの合成）に依存するので、macOS の更新で動かなくなることがある。macOS 27 のイベント形式には未対応。
- UUID が空のデスクトップには名前を付けられない。
- スワイプはカーソルのあるディスプレイに効くので、カーソルが移動先と別のディスプレイにあるときは、既定でカーソルも移動先へ動く。`--restore-cursor` で元に戻せる。

## データ

`~/.config/deskman/` に保存する。消すにはこのフォルダを削除する。

## 謝辞

スワイプ合成の手法は [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)（MIT）と [yabai](https://github.com/koekeishiya/yabai)（MIT）を参考にした。

## ライセンス

MIT。`LICENSE` を参照。
