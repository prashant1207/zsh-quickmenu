# quickmenu :: registry
# Holds the list of menu items declared by the user's config.

typeset -ga _QM_LABEL _QM_CMD _QM_GROUP _QM_DESC _QM_COND _QM_FLAGS

qm_reset() {
  _QM_LABEL=(); _QM_CMD=(); _QM_GROUP=(); _QM_DESC=(); _QM_COND=(); _QM_FLAGS=()
}

# qm_item [-g group] [-d description] [-c condition] [-e] [-y] <label> <command>
#
#   -g, --group    group heading shown before the label
#   -d, --desc     longer description (used for fuzzy matching only)
#   -c, --if       shell condition; the item is hidden unless it exits 0
#   -e, --edit     put the command on the prompt instead of running it
#   -y, --confirm  ask y/N before running
#
# Options may appear before or after the label/command. Use `--` if a literal
# argument would otherwise look like an option.
qm_item() {
  emulate -L zsh
  local group='' desc='' cond='' flags=''
  local -a pos

  while (( $# )); do
    case $1 in
      -g|--group)   group=$2; shift 2 || return 1 ;;
      -d|--desc)    desc=$2;  shift 2 || return 1 ;;
      -c|--if)      cond=$2;  shift 2 || return 1 ;;
      -e|--edit)    flags+='e'; shift ;;
      -y|--confirm) flags+='y'; shift ;;
      --)           shift; pos+=( "$@" ); break ;;
      *)            pos+=( "$1" ); shift ;;
    esac
  done

  if (( $#pos < 2 )); then
    print -ru2 -- "qm_item: usage: qm_item [-g group] [-d desc] [-c cond] [-e] [-y] <label> <command>"
    return 1
  fi

  _QM_LABEL+=( "${pos[1]}" )
  _QM_CMD+=( "${pos[2]}" )
  _QM_GROUP+=( "$group" )
  _QM_DESC+=( "$desc" )
  _QM_COND+=( "$cond" )
  _QM_FLAGS+=( "$flags" )
}

# Items only shown inside a git work tree.
qm_git_item() {
  emulate -L zsh
  qm_item -c 'git rev-parse --is-inside-work-tree' "$@"
}

# Resolve which items are currently visible (conditions satisfied).
# Fills _qm_vis_idx / _qm_vis_label / _qm_vis_cmd / _qm_vis_flags / _qm_vis_hay.
_qm_visible() {
  emulate -L zsh
  typeset -ga _qm_vis_idx=() _qm_vis_label=() _qm_vis_cmd=() _qm_vis_flags=() _qm_vis_hay=()
  local -i i
  for (( i = 1; i <= $#_QM_LABEL; i++ )); do
    if [[ -n ${_QM_COND[i]} ]]; then
      eval "${_QM_COND[i]}" >/dev/null 2>&1 || continue
    fi
    _qm_vis_idx+=( $i )
    if [[ -n ${_QM_GROUP[i]} ]]; then
      _qm_vis_label+=( "${_QM_GROUP[i]}: ${_QM_LABEL[i]}" )
    else
      _qm_vis_label+=( "${_QM_LABEL[i]}" )
    fi
    _qm_vis_cmd+=( "${_QM_CMD[i]}" )
    _qm_vis_flags+=( "${_QM_FLAGS[i]}" )
    _qm_vis_hay+=( "${_QM_LABEL[i]} ${_QM_GROUP[i]} ${_QM_DESC[i]} ${_QM_CMD[i]}" )
  done
  (( $#_qm_vis_idx ))
}
