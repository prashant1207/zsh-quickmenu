#
# quickmenu - launcher menu for the commands you keep forgetting
# https://github.com/ -- drop this directory anywhere and source the file below.
#
#   source /path/to/zsh-quickmenu/quickmenu.plugin.zsh
#
# or, with oh-my-zsh:  plugins=( ... quickmenu )
#

0="${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}"
typeset -g QUICKMENU_ROOT="${0:A:h}"

source "$QUICKMENU_ROOT/lib/registry.zsh"
source "$QUICKMENU_ROOT/lib/picker.zsh"
source "$QUICKMENU_ROOT/lib/resolve.zsh"
source "$QUICKMENU_ROOT/lib/config.zsh"
source "$QUICKMENU_ROOT/lib/core.zsh"

# Short alias, unless the name is already taken.
if (( ! ${+functions[qm]} )) && (( ! ${+commands[qm]} )) && (( ! ${+aliases[qm]} )); then
  qm() { quickmenu "$@" }
fi

# Keybinding (default Ctrl-G). Set QUICKMENU_KEY='' to skip the binding.
if [[ -o interactive ]]; then
  zle -N quickmenu-widget
  typeset -g QUICKMENU_KEY=${QUICKMENU_KEY-'^G'}
  [[ -n $QUICKMENU_KEY ]] && bindkey "$QUICKMENU_KEY" quickmenu-widget
fi

# Completion for `qm <query>`: offer the item labels.
_quickmenu_complete() {
  local -a labels
  _qm_load_config
  _qm_visible || return 1
  labels=( ${_qm_vis_label//:/\\:} )
  _describe -t quickmenu 'menu item' labels
}
if (( ${+functions[compdef]} )); then
  compdef _quickmenu_complete quickmenu qm 2>/dev/null
fi
