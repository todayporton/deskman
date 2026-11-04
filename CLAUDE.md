# deskman

macOS のデスクトップに名前を付けて瞬時に移動するツール。使い方と終了コードは `README.md`（英語）、日本語版は `README.ja.md` で、変えるときは両方を直す。設計の経緯と実測結果は `docs/plans/2026-11-03-deskman-design.md` を参照する。`docs/plans/2026-11-03-deskman.md` は当初の実装計画で、コードの正は `Sources/`。

## 構成

- 1つのバイナリが、引数なしならメニューバー常駐、引数ありなら CLI として動く。
- `deskman go` はソケット（`~/.config/deskman/deskman.sock`）で Deskman.app に移動を依頼する。アクセシビリティ権限は Deskman.app だけに持たせる。Herdr のターミナルは `herdr-core` の配下で動くので、CLI から直接スワイプを送る構成には戻さない。
- 名前は UUID に紐づけて `~/.config/deskman/names.json` に保存する。番号と数値 ID は変わるので保存しない。
- 非公式 API は `SystemSpaces.swift` と `SpaceSwitcher.swift` に閉じ込める。Mission Control の Dock の要素の構造（公開された仕様ではない）を読むのは `MissionControlOverlay.swift` だけにする。

## 要件

- 切り替えは瞬時が理想で、無理でも非常に高速であること。方式の選択では互換性や実装の簡単さより優先する。
- `--json` の出力と終了コードは Herdr モッドから使う前提なので、変えるときは互換性に注意する。

## ビルドと確認

- テスト: `swift test`
- この Mac に入れるビルド: `CODESIGN_IDENTITY=todayporton bash scripts/bundle.sh`。指定を忘れるとアドホック署名になり、アクセシビリティ権限の入れ直しが必要になることがある。`todayporton` で署名したビルドなら、入れ替えても権限は保たれる（2026-11-03、Homebrew で 0.1.0 から 0.2.0 に更新して確認）。
- この Mac の `/Applications/Deskman.app` は Homebrew の cask で入れたもので、ログイン時にはこちらが起動する。開発版で上書きしない。
- 開発版はコピーせず `dist/` から起動して確認する。切り替えはユーザーが行う。どの `deskman` コマンドも、動いている方の Deskman.app にソケットで依頼する。

```
pkill -x deskman; sleep 1; open dist/Deskman.app                 # 開発版で試す
pkill -x deskman; sleep 1; open /Applications/Deskman.app        # brew 版に戻す
```

- 開発版を起動している間は、メニューの「Launch at Login」を切り替えない。切り替えると、ログイン項目が `dist/` の方に登録されることがある。

- 実際にデスクトップが切り替わる操作（`deskman go`、`spike/`）を、開発中にホストの Mac で自動実行しない。`macvm` スキルで VM で確認する。ホストで実行してよいのは `list` と `current` だけ。
- VM は他のセッションと共有している。`macvm lock-status` を確認し、他のセッションがロックを持っているときは切り替えを実行せず、強制解除もしない。
- VM はディスプレイ1台で、先頭のデスクトップの UUID が空になることがある。ディスプレイ2台の動作は、ユーザーに実機で確認してもらう。

## 未確認

自動起動、この Mac での並べ替えと増減、Mission Control の名前表示のフルスクリーンのデスクトップ、`move` のディスプレイ2台の1台目・タイトルバーのないウィンドウ、外部ディスプレイを抜いている間の移動、再起動後の UUID。macOS 27 の形式は Raycast の実装を読んで組み込んだが、実機では未確認（設計資料の「Raycast の実装」を参照）。
