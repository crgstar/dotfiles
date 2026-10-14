# why: ログインシェルとして起動した bash（ターミナルの新規タブ等）は .bashrc を読まないため、ここから読ませる
[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"
