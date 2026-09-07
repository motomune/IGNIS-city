# この枝（gh-pages）について

ここには **転送ページしか置かない**。

理由：本（SOUL）の紙面に `https://motomune.github.io/IGNIS-city/...` と
印刷してしまっている。紙は直せないので、このURLを永久に生かしておく必要がある。
GitHub Pages の無料枠は公開リポジトリでしか使えないため、リポジトリ自体は公開のまま、
中身を「案内板」だけにしてある。

- サイトの本体は **main** ブランチ → Cloudflare Workers（ignis-city）
- ゲーム https://ignis-city.motomune.com ／ 人の側 https://motomune.com
- GitHub Pages は **この枝** を見る（Settings → Pages → Branch: gh-pages）

`404.html` が受け皿になっていて、`/IGNIS-city/なにか` で来た人は
`https://ignis-city.motomune.com/なにか` へ引きつがれる。本に書いたURLを思い出せなくても取りこぼさない。

- 人の側に残るのは /links と /ant-nest。それ以外の行き先は https://ignis-city.motomune.com

転送先を変えるときは `SITE` を書きかえた各ファイルを差しかえる。
