#!/usr/bin/env zsh
#
# quickmenu installer.
#
# Links the plugin into oh-my-zsh if it finds one, otherwise prints the single
# line to add to ~/.zshrc. Safe to re-run.
#
#   git clone https://github.com/prashant1207/zsh-quickmenu ~/.zsh/zsh-quickmenu
#   ~/.zsh/zsh-quickmenu/install.sh
#

emulate -L zsh
setopt err_exit no_unset pipe_fail

ROOT=${0:A:h}
OMZ_CUSTOM=${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}

if [[ ! -f $ROOT/quickmenu.plugin.zsh ]]; then
  print -ru2 -- "quickmenu: can't find quickmenu.plugin.zsh next to this script"
  exit 1
fi

print -r -- "quickmenu: plugin at ${ROOT}"

if [[ -d $OMZ_CUSTOM ]]; then
  target=$OMZ_CUSTOM/plugins/quickmenu
  mkdir -p ${target:h}
  if [[ -L $target ]]; then
    rm -f -- "$target"
  elif [[ -e $target ]]; then
    print -ru2 -- "quickmenu: ${target} already exists and isn't a symlink; leaving it alone"
    exit 1
  fi
  ln -s -- "$ROOT" "$target"
  print -r -- "quickmenu: linked -> ${target}"
  print -r -- ""
  print -r -- "Add 'quickmenu' to the plugins list in ~/.zshrc:"
  print -r -- "    plugins=( ... quickmenu )"
else
  print -r -- ""
  print -r -- "Add this to ~/.zshrc:"
  print -r -- "    source ${ROOT}/quickmenu.plugin.zsh"
fi

print -r -- ""
print -r -- "Then: exec zsh   and press Ctrl-G (or run 'qm')."
